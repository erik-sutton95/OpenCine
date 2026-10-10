// Shared Bitmap pipeline. Uses the SAME OpcVk command buffer, queue,
// acquisition lifetime, swapchain and per-image present synchronization.
// Every function is invoked under OpcVk::lock after waiting its GPU fence.

static void destroyBitmapFeed(OpcVk* r) {
    auto& b = r->bitmap;
    if (b.pipeline) vkDestroyPipeline(r->device, b.pipeline, nullptr);
    if (b.layout) vkDestroyPipelineLayout(r->device, b.layout, nullptr);
    if (b.pool) vkDestroyDescriptorPool(r->device, b.pool, nullptr);
    if (b.setLayout) vkDestroyDescriptorSetLayout(r->device, b.setLayout, nullptr);
    destroyImage(r->device, &b.source.image);
    for (auto& cube : b.cubes) destroyImage(r->device, &cube.image);
    destroyBuffer(r->device, &b.staging);
    destroyBuffer(r->device, &b.uniform);
    b = {};
}

static bool uploadBitmapFeedImage(
    OpcVk* r, BitmapFeedImage* target, uint32_t width, uint32_t height,
    VkFormat format, const uint8_t* bytes, size_t byteCount
) {
    auto& b = r->bitmap;
    if (b.failed || !width || !height || !bytes ||
        static_cast<uint64_t>(width) * height * 4 != byteCount) return false;
    if (!waitFence(r, "bitmap upload")) { b.failed = true; return false; }
    ImageMem replacement{};
    const bool resize = target->image.width != width || target->image.height != height;
    if (resize && makeImage(r, width, height, format,
            VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT, &replacement)) {
        destroyImage(r->device, &replacement);
        return false;
    }
    if (b.staging.size < byteCount) {
        BufferMem next{};
        if (makeBuffer(r, byteCount, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &next)) {
            destroyImage(r->device, &replacement);
            destroyBuffer(r->device, &next);
            return false;
        }
        destroyBuffer(r->device, &b.staging);
        b.staging = next;
    }
    memcpy(b.staging.mapped, bytes, byteCount);
    ImageMem* output = resize ? &replacement : &target->image;
    vkResetCommandBuffer(r->cmd, 0);
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    if (vkBeginCommandBuffer(r->cmd, &begin) != VK_SUCCESS) {
        destroyImage(r->device, &replacement);
        b.failed = true;
        return false;
    }
    imageBarrier(r->cmd, output->image,
        !resize && target->shaderReady ? VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_UNDEFINED,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_ACCESS_SHADER_READ_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
        VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
    VkBufferImageCopy copy{};
    copy.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
    copy.imageExtent = {width, height, 1};
    vkCmdCopyBufferToImage(r->cmd, b.staging.buffer, output->image,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &copy);
    imageBarrier(r->cmd, output->image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT,
        VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
    if (vkEndCommandBuffer(r->cmd) != VK_SUCCESS) {
        destroyImage(r->device, &replacement);
        b.failed = true;
        return false;
    }
    vkResetFences(r->device, 1, &r->fence);
    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &r->cmd;
    if (vkQueueSubmit(r->queue, 1, &submit, r->fence) != VK_SUCCESS) {
        // No successful submission owns replacement. Renderer teardown/rebuild
        // retains the unsignaled-fence handling already used by the shared owner.
        destroyImage(r->device, &replacement);
        r->swapchainHealthy = false;
        b.failed = true;
        return false;
    }
    if (!waitFence(r, "bitmap upload completion")) {
        // An in-flight image must stay owned until device-idle teardown.
        // The detached slot is retained separately, never destroyed on timeout.
        if (resize) r->bitmapPendingImages.push_back(replacement);
        r->swapchainHealthy = false;
        b.failed = true;
        return false;
    }
    if (resize) {
        destroyImage(r->device, &target->image);
        target->image = replacement;
    }
    target->shaderReady = true;
    return true;
}

static bool ensureBitmapFeedResources(OpcVk* r) {
    auto& b = r->bitmap;
    if (b.failed) return false;
    const auto refuse = [&b]() { b.failed = true; return false; };
    if (!b.setLayout) {
        auto sampler = [](uint32_t binding) {
            return VkDescriptorSetLayoutBinding{
                binding, VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1,
                VK_SHADER_STAGE_FRAGMENT_BIT, nullptr};
        };
        VkDescriptorSetLayoutBinding params{
            2, VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1, VK_SHADER_STAGE_FRAGMENT_BIT, nullptr};
        b.setLayout = makeSetLayout(r->device, {sampler(0), sampler(1), params, sampler(3), sampler(4)});
        if (!b.setLayout) return refuse();
        b.layout = makeLayout(r->device, b.setLayout, VK_SHADER_STAGE_FRAGMENT_BIT, 0);
        if (!b.layout) return refuse();
        VkDescriptorPoolSize sizes[] = {
            {VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 4},
            {VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1},
        };
        VkDescriptorPoolCreateInfo pool{VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO};
        pool.maxSets = 1; pool.poolSizeCount = 2; pool.pPoolSizes = sizes;
        if (vkCreateDescriptorPool(r->device, &pool, nullptr, &b.pool)) return refuse();
        VkDescriptorSetAllocateInfo allocation{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO};
        allocation.descriptorPool = b.pool;
        allocation.descriptorSetCount = 1;
        allocation.pSetLayouts = &b.setLayout;
        if (vkAllocateDescriptorSets(r->device, &allocation, &b.set)) return refuse();
        if (makeBuffer(r, sizeof(BitmapFeedParams), VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
                VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT, &b.uniform)) return refuse();
        writeBuffer(r->device, b.set, 2, b.uniform.buffer, sizeof(BitmapFeedParams),
            VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER);
        const uint8_t identity[16] = {
            0,0,0,255, 255,255,255,255, 0,0,0,255, 255,255,255,255};
        for (auto& cube : b.cubes) {
            if (!uploadBitmapFeedImage(r, &cube, 2, 2, VK_FORMAT_R8G8B8A8_UNORM,
                    identity, sizeof(identity))) return refuse();
        }
    }
    if (!b.set || !b.uniform.mapped || !b.cubes[0].shaderReady ||
        !b.cubes[1].shaderReady || !b.cubes[2].shaderReady) return refuse();
    return true;
}

static bool ensureBitmapFeedPipeline(OpcVk* r) {
    auto& b = r->bitmap;
    if (!ensureBitmapFeedResources(r)) return false;
    if (b.pipeline && b.pipelineFormat == r->swapFormat) return true;
    // Attach/resize retires old swapchain GPU work before replacing its pass.
    if (!waitFence(r, "bitmap pipeline")) return false;
    if (b.pipeline) vkDestroyPipeline(r->device, b.pipeline, nullptr);
    b.pipeline = VK_NULL_HANDLE;
    auto vs = makeShader(r->device, bitmap_feed_vert_spv, bitmap_feed_vert_spv_count);
    auto fs = makeShader(r->device, bitmap_feed_frag_spv, bitmap_feed_frag_spv_count);
    b.pipeline = makeGfx(r, b.layout, r->swapPass, vs, fs, false, false, 0);
    vkDestroyShaderModule(r->device, vs, nullptr);
    vkDestroyShaderModule(r->device, fs, nullptr);
    b.pipelineFormat = r->swapFormat;
    return b.pipeline != VK_NULL_HANDLE;
}

static bool renderBitmapFeed(OpcVk* r) {
    auto& b = r->bitmap;
    if (b.failed) return false;
    if (b.paused || !b.hasFrame || !r->swapchain || !r->window) return true;
    if (!r->swapchainHealthy || !waitFence(r, "bitmap present") || !ensureBitmapFeedPipeline(r)) return false;
    uint32_t index = r->acquiredImage;
    if (!acquireFrameImage(r, &index)) return false;
    memcpy(b.uniform.mapped, &b.params, sizeof(b.params));
    writeCombined(r->device, b.set, 0, b.source.image.view, r->linearSampler);
    writeCombined(r->device, b.set, 1, b.cubes[0].image.view, r->linearSampler);
    writeCombined(r->device, b.set, 3, b.cubes[1].image.view, r->linearSampler);
    writeCombined(r->device, b.set, 4, b.cubes[2].image.view, r->linearSampler);
    vkResetCommandBuffer(r->cmd, 0);
    VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    if (vkBeginCommandBuffer(r->cmd, &begin) != VK_SUCCESS) return false;
    beginPass(r->cmd, r->swapPass, r->swapFbs[index], r->swapExtent.width, r->swapExtent.height, true);
    const float sw = r->swapExtent.width, sh = r->swapExtent.height;
    float vw = sw, vh = sh, vx = 0, vy = 0;
    if (b.params.aspectFill < 0.5f && b.source.image.width && b.source.image.height) {
        const float source = static_cast<float>(b.source.image.width) / b.source.image.height;
        if (source > sw / sh) { vh = sw / source; vy = (sh - vh) * 0.5f; }
        else { vw = sh * source; vx = (sw - vw) * 0.5f; }
    }
    VkViewport viewport{vx, vy, vw, vh, 0, 1};
    VkRect2D scissor{{static_cast<int32_t>(vx), static_cast<int32_t>(vy)},
        {static_cast<uint32_t>(vw), static_cast<uint32_t>(vh)}};
    vkCmdSetViewport(r->cmd, 0, 1, &viewport);
    vkCmdSetScissor(r->cmd, 0, 1, &scissor);
    vkCmdBindPipeline(r->cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, b.pipeline);
    vkCmdBindDescriptorSets(r->cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, b.layout, 0, 1, &b.set, 0, nullptr);
    vkCmdDraw(r->cmd, 3, 1, 0, 0);
    vkCmdEndRenderPass(r->cmd);
    return submitAndPresentFrame(r, index, false);
}
