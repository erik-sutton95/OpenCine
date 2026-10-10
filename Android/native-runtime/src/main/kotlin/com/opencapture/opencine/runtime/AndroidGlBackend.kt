package com.opencapture.opencine.runtime

import android.content.Context
import android.graphics.Bitmap
import android.opengl.GLES11Ext
import android.opengl.GLES20
import android.opengl.GLUtils
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.FloatBuffer

/** All native calls occur on the owning renderer's current GL thread/context. */
internal class AndroidGlBackend(private val context: Context) : NativeGlBackend {
    override val homogeneousCoordinateVectorSize = 4
    override fun normalizedCoordinateBounds() = floatArrayOf(
        -1f, -1f, 0f, 1f, 1f, -1f, 0f, 1f, -1f, 1f, 0f, 1f, 1f, 1f, 0f, 1f,
    )

    override fun createProgram(vertexAsset: String, fragmentAsset: String): NativeGlProgram =
        FrameworkGlProgram(context.assets.open(vertexAsset).bufferedReader().use { it.readText() },
            context.assets.open(fragmentAsset).bufferedReader().use { it.readText() })

    private fun texture(upload: () -> Unit): Int {
        val names = IntArray(1)
        GLES20.glGenTextures(1, names, 0)
        check(names[0] != 0) { "GL texture allocation failed" }
        try {
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, names[0])
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE)
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE)
            upload()
            checkError()
            return names[0]
        } catch (error: Throwable) {
            GLES20.glDeleteTextures(1, names, 0)
            throw error
        }
    }
    override fun createTexture(width: Int, height: Int): Int {
        require(width > 0 && height > 0)
        return texture { GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA,
            width, height, 0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null) }
    }
    override fun createTexture(bitmap: Bitmap): Int = texture {
        GLUtils.texImage2D(GLES20.GL_TEXTURE_2D, 0, bitmap, 0)
    }
    override fun createFramebuffer(texture: Int): Int {
        val names = IntArray(1)
        GLES20.glGenFramebuffers(1, names, 0)
        check(names[0] != 0) { "GL framebuffer allocation failed" }
        try {
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, names[0])
            GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
                GLES20.GL_TEXTURE_2D, texture, 0)
            check(GLES20.glCheckFramebufferStatus(GLES20.GL_FRAMEBUFFER) == GLES20.GL_FRAMEBUFFER_COMPLETE) {
                "GL framebuffer is incomplete"
            }
            checkError()
            return names[0]
        } catch (error: Throwable) {
            GLES20.glDeleteFramebuffers(1, names, 0)
            throw error
        }
    }
    override fun focusFramebuffer(framebuffer: Int, width: Int, height: Int) {
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer)
        GLES20.glViewport(0, 0, width, height)
        checkError()
    }
    override fun deleteFramebuffer(framebuffer: Int) {
        GLES20.glDeleteFramebuffers(1, intArrayOf(framebuffer), 0)
        checkError()
    }
    override fun deleteTexture(texture: Int) {
        GLES20.glDeleteTextures(1, intArrayOf(texture), 0)
        checkError()
    }
    override fun checkError() = checkFrameworkGlError()
}

private fun checkFrameworkGlError() {
    val errors = mutableListOf<Int>()
    var value = GLES20.glGetError()
    // A lost context can keep reporting an error; retain diagnostics without stalling its owner.
    while (value != GLES20.GL_NO_ERROR && errors.size < 32) {
        errors.add(value)
        value = GLES20.glGetError()
    }
    check(errors.isEmpty()) { "GL errors: ${errors.joinToString { "0x" + it.toString(16) }}" }
}

private class FrameworkGlProgram(vertex: String, fragment: String) : NativeGlProgram {
    private val program = GLES20.glCreateProgram().also { check(it != 0) }
    private var deleted = false
    private data class Attribute(val location: Int, val values: FloatBuffer, val size: Int)
    private data class Uniform(val location: Int, val type: Int, val count: Int,
        var values: FloatArray? = null, var sampler: Pair<Int, Int>? = null)
    private val attributes = linkedMapOf<String, Attribute>()
    private val uniforms = linkedMapOf<String, Uniform>()

    init {
        val shaders = mutableListOf<Int>()
        try {
            for ((type, source) in listOf(GLES20.GL_VERTEX_SHADER to vertex, GLES20.GL_FRAGMENT_SHADER to fragment)) {
                val shader = GLES20.glCreateShader(type)
                check(shader != 0) { "GL shader allocation failed" }
                shaders.add(shader)
                GLES20.glShaderSource(shader, source)
                GLES20.glCompileShader(shader)
                val compiled = IntArray(1)
                GLES20.glGetShaderiv(shader, GLES20.GL_COMPILE_STATUS, compiled, 0)
                check(compiled[0] != 0) { GLES20.glGetShaderInfoLog(shader) }
                GLES20.glAttachShader(program, shader)
            }
            GLES20.glLinkProgram(program)
            val linked = IntArray(1)
            GLES20.glGetProgramiv(program, GLES20.GL_LINK_STATUS, linked, 0)
            check(linked[0] != 0) { GLES20.glGetProgramInfoLog(program) }
            val count = IntArray(1)
            GLES20.glGetProgramiv(program, GLES20.GL_ACTIVE_UNIFORMS, count, 0)
            repeat(count[0]) { index ->
                val size = IntArray(1); val type = IntArray(1)
                val name = GLES20.glGetActiveUniform(program, index, size, 0, type, 0)
                val uniform = Uniform(GLES20.glGetUniformLocation(program, name), type[0], size[0])
                uniforms[name] = uniform
                if (name.endsWith("[0]")) uniforms[name.removeSuffix("[0]")] = uniform
            }
            checkFrameworkGlError()
        } catch (error: Throwable) {
            GLES20.glDeleteProgram(program)
            deleted = true
            throw error
        } finally {
            shaders.forEach(GLES20::glDeleteShader)
        }
    }
    override fun use() { check(!deleted); GLES20.glUseProgram(program); checkFrameworkGlError() }
    override fun setBufferAttribute(name: String, values: FloatArray, size: Int) {
        check(!deleted)
        require(size in 1..4 && values.size % size == 0)
        val location = GLES20.glGetAttribLocation(program, name)
        require(location >= 0) { "Missing GL attribute $name" }
        val buffer = ByteBuffer.allocateDirect(values.size * Float.SIZE_BYTES)
            .order(ByteOrder.nativeOrder()).asFloatBuffer().apply { put(values); position(0) }
        attributes[name] = Attribute(location, buffer, size)
    }
    override fun setFloatsUniform(name: String, values: FloatArray) {
        check(!deleted)
        val uniform = requireNotNull(uniforms[name]) { "Missing GL uniform $name" }
        uniform.values = values.copyOf()
    }
    override fun setSamplerTexIdUniform(name: String, texture: Int, unit: Int) {
        check(!deleted)
        require(texture > 0 && unit >= 0)
        val uniform = requireNotNull(uniforms[name]) { "Missing GL sampler $name" }
        require(uniform.type == GLES20.GL_SAMPLER_2D || uniform.type == GLES11Ext.GL_SAMPLER_EXTERNAL_OES)
        uniform.sampler = texture to unit
    }
    override fun bindAttributesAndUniforms() {
        check(!deleted)
        attributes.values.forEach {
            it.values.position(0)
            GLES20.glBindBuffer(GLES20.GL_ARRAY_BUFFER, 0)
            GLES20.glVertexAttribPointer(it.location, it.size, GLES20.GL_FLOAT, false, 0, it.values)
            GLES20.glEnableVertexAttribArray(it.location)
        }
        uniforms.values.distinct().forEach { uniform ->
            uniform.sampler?.let { (texture, unit) ->
                GLES20.glActiveTexture(GLES20.GL_TEXTURE0 + unit)
                GLES20.glBindTexture(if (uniform.type == GLES11Ext.GL_SAMPLER_EXTERNAL_OES)
                    GLES11Ext.GL_TEXTURE_EXTERNAL_OES else GLES20.GL_TEXTURE_2D, texture)
                GLES20.glUniform1i(uniform.location, unit)
            }
            uniform.values?.let { values ->
                val count = uniform.count
                val components = when (uniform.type) {
                    GLES20.GL_FLOAT -> 1; GLES20.GL_FLOAT_VEC2 -> 2; GLES20.GL_FLOAT_VEC3 -> 3
                    GLES20.GL_FLOAT_VEC4 -> 4; GLES20.GL_FLOAT_MAT3 -> 9; GLES20.GL_FLOAT_MAT4 -> 16
                    else -> error("GL uniform is not float-valued")
                }
                require(values.size == components * count) { "Invalid GL uniform value length" }
                when (uniform.type) {
                    GLES20.GL_FLOAT -> GLES20.glUniform1fv(uniform.location, count, values, 0)
                    GLES20.GL_FLOAT_VEC2 -> GLES20.glUniform2fv(uniform.location, count, values, 0)
                    GLES20.GL_FLOAT_VEC3 -> GLES20.glUniform3fv(uniform.location, count, values, 0)
                    GLES20.GL_FLOAT_VEC4 -> GLES20.glUniform4fv(uniform.location, count, values, 0)
                    GLES20.GL_FLOAT_MAT3 -> GLES20.glUniformMatrix3fv(uniform.location, count, false, values, 0)
                    GLES20.GL_FLOAT_MAT4 -> GLES20.glUniformMatrix4fv(uniform.location, count, false, values, 0)
                }
            }
        }
        checkFrameworkGlError()
    }
    override fun delete() {
        if (deleted) return
        deleted = true
        GLES20.glDeleteProgram(program)
        attributes.clear(); uniforms.clear()
        checkFrameworkGlError()
    }
}
