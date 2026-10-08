package com.opencapture.opencine.runtime

import android.graphics.Bitmap
import android.content.Context

/** Existing application GL helper implementation. Every call runs on the current GL thread. */
interface NativeGlBackend {
    companion object {
        /** Framework GLES implementation; no application renderer or third-party helper required. */
        fun create(context: Context): NativeGlBackend = AndroidGlBackend(context.applicationContext)
    }
    fun createProgram(vertexAsset: String, fragmentAsset: String): NativeGlProgram
    fun normalizedCoordinateBounds(): FloatArray
    val homogeneousCoordinateVectorSize: Int
    fun createTexture(width: Int, height: Int): Int
    fun createTexture(bitmap: Bitmap): Int
    fun createFramebuffer(texture: Int): Int
    fun focusFramebuffer(framebuffer: Int, width: Int, height: Int)
    fun deleteFramebuffer(framebuffer: Int)
    fun deleteTexture(texture: Int)
    fun checkError()
}

interface NativeGlProgram {
    fun use()
    fun setBufferAttribute(name: String, values: FloatArray, size: Int)
    fun setFloatsUniform(name: String, values: FloatArray)
    fun setSamplerTexIdUniform(name: String, texture: Int, unit: Int)
    fun bindAttributesAndUniforms()
    fun delete()
}
