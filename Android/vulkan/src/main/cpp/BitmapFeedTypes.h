// Bitmap image/graph configuration inside the existing OpcVk renderer.
// This file is included after the common target, descriptor and WSI helpers.
struct BitmapFeedParams {
    float lutSize = 0, peakingOn = 0, zebraHiOn = 0, zebraMidOn = 0;
    float peakingColor[4]{1, 72.f / 255.f, 64.f / 255.f, 0};
    float zebraHiColor[4]{1, 1, 1, 0};
    float zebraMidColor[4]{1, 0.72f, 0.2f, 0};
    float peakingRatio = 2.10f, peakingGate = 0.00174f, zebraHi = 1, zebraMid = 0.5f;
    float aspectFill = 0, splitOn = 0, splitVertical = 1, mirror = 0;
    float deLog[4]{}, deLogTail = 0, deLogPad = 0, sourceSize[2]{};
    float paintSize = 0, weightSize = 0, limitsOn = 0, limitsPad = 0;
    float highlightMaximum = 1, zebraBias = 1, midtoneHalf = 5.f / 255.f, mirrorVertical = 0;
};
static_assert(offsetof(BitmapFeedParams, sourceSize) == 120, "bitmap source extent matches shader");
static_assert(offsetof(BitmapFeedParams, limitsOn) == 136, "bitmap limits match shader");
static_assert(offsetof(BitmapFeedParams, mirrorVertical) == 156, "bitmap vertical mirror matches shader");
static_assert(sizeof(BitmapFeedParams) == 160, "bitmap uniform range matches shader");

struct BitmapFeedImage {
    ImageMem image{};
    bool shaderReady = false;
};
struct BitmapFeed {
    bool failed = false;
    bool paused = true;
    bool hasFrame = false;
    BitmapFeedParams params{};
    BitmapFeedImage source{}, cubes[3]{};
    BufferMem staging{}, uniform{};
    VkDescriptorSetLayout setLayout = VK_NULL_HANDLE;
    VkPipelineLayout layout = VK_NULL_HANDLE;
    VkDescriptorSet set = VK_NULL_HANDLE;
    VkDescriptorPool pool = VK_NULL_HANDLE;
    VkPipeline pipeline = VK_NULL_HANDLE;
    VkFormat pipelineFormat = VK_FORMAT_MAX_ENUM;
};
