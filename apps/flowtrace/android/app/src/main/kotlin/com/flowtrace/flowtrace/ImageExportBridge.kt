package com.flowtrace.flowtrace

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.Executors

/** Writes only to the single document chosen in this Activity instance. */
internal class ImageExportBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private data class Selection(
        val token: String,
        val uri: Uri,
        val finalName: String,
        @Volatile var phase: String = "chosen",
    )

    private val channel = MethodChannel(messenger, "flowtrace/image_export")
    private val io = Executors.newSingleThreadExecutor()
    private val lock = Any()
    private var pickerResult: MethodChannel.Result? = null
    private var pickerToken: String? = null
    private var selection: Selection? = null
    @Volatile private var closed = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (closed) {
            result.error("image_export_interrupted", "图片导出已中止。", null)
            return
        }
        when (call.method) {
            "choose" -> choose(result)
            "stage" -> stage(call, result)
            "commit" -> commit(call, result)
            "discard" -> discard(call, result)
            else -> result.notImplemented()
        }
    }

    private fun choose(result: MethodChannel.Result) {
        if (pickerResult != null || synchronized(lock) { selection != null }) {
            result.error("image_export_busy", "已有图片导出尚未结束。", null)
            return
        }
        val token = UUID.randomUUID().toString()
        pickerResult = result
        pickerToken = token
        // A failed/interrupted write never looks like a completed archive.
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/zip"
            putExtra(Intent.EXTRA_TITLE, "flowtrace-images-${token.take(8)}.partial.zip")
        }
        try {
            activity.startActivityForResult(intent, REQUEST_CODE)
        } catch (_: Exception) {
            pickerResult = null
            pickerToken = null
            result.error("image_export_picker_unavailable", "无法打开系统保存位置。", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_CODE) return false
        val reply = pickerResult
        val token = pickerToken
        pickerResult = null
        pickerToken = null
        val uri = data?.data
        if (reply == null || token == null) return true
        if (resultCode != Activity.RESULT_OK || uri == null) {
            reply.success(null)
            return true
        }
        if (uri.scheme != "content" || !DocumentsContract.isDocumentUri(activity, uri)) {
            reply.error("image_export_invalid_destination", "所选位置不支持受控文件导出。", null)
            return true
        }
        synchronized(lock) {
            selection = Selection(token, uri, "flowtrace-images-${token.take(8)}.zip")
        }
        reply.success(token)
        return true
    }

    private fun selected(call: MethodCall): Selection? {
        val token = call.argument<String>("token") ?: return null
        return synchronized(lock) { selection?.takeIf { it.token == token } }
    }

    private fun stage(call: MethodCall, result: MethodChannel.Result) {
        val chosen = selected(call)
        val bytes = call.argument<ByteArray>("bytes")
        if (chosen == null || chosen.phase != "chosen" || bytes == null ||
            bytes.size !in 4..MAX_ZIP_BYTES ||
            bytes[0] != 0x50.toByte() || bytes[1] != 0x4b.toByte() ||
            bytes[2] != 0x03.toByte() || bytes[3] != 0x04.toByte()
        ) {
            result.error("image_export_invalid_destination", "图片导出请求已失效。", null)
            return
        }
        synchronized(lock) { chosen.phase = "writing" }
        io.execute {
            try {
                activity.contentResolver.openOutputStream(chosen.uri, "wt").use { stream ->
                    requireNotNull(stream)
                    stream.write(bytes)
                    stream.flush()
                }
                synchronized(lock) {
                    check(!closed && selection === chosen)
                    chosen.phase = "staged"
                }
                reply { result.success(null) }
            } catch (_: Exception) {
                remove(chosen)
                reply { result.error("image_export_write_failed", "图片文件保存失败。", null) }
            }
        }
    }

    private fun commit(call: MethodCall, result: MethodChannel.Result) {
        val chosen = selected(call)
        if (chosen == null || chosen.phase != "staged") {
            result.error("image_export_invalid_destination", "图片导出尚未完整写入。", null)
            return
        }
        synchronized(lock) { chosen.phase = "committing" }
        io.execute {
            try {
                check(!closed)
                val published = DocumentsContract.renameDocument(
                    activity.contentResolver, chosen.uri, chosen.finalName,
                )
                requireNotNull(published)
                synchronized(lock) {
                    chosen.phase = "committed"
                    if (selection === chosen) selection = null
                }
                reply { result.success(null) }
            } catch (_: Exception) {
                remove(chosen)
                reply { result.error("image_export_publish_failed", "所选位置无法完成图片导出。", null) }
            }
        }
    }

    private fun discard(call: MethodCall, result: MethodChannel.Result) {
        val chosen = selected(call)
        if (chosen == null) {
            result.success(null)
            return
        }
        io.execute {
            val removed = remove(chosen)
            reply {
                if (removed) result.success(null)
                else result.error("image_export_cleanup_failed", "未完成文件清理失败，文件仍标为partial。", null)
            }
        }
    }

    private fun remove(chosen: Selection): Boolean {
        synchronized(lock) {
            if (chosen.phase == "committed") return true
            if (selection === chosen) selection = null
        }
        return try {
            DocumentsContract.deleteDocument(activity.contentResolver, chosen.uri)
        } catch (_: Exception) {
            false
        }
    }

    private fun reply(action: () -> Unit) {
        activity.runOnUiThread {
            if (!closed) action()
        }
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        pickerResult?.error("image_export_interrupted", "图片导出已中止。", null)
        pickerResult = null
        pickerToken = null
        val unfinished = synchronized(lock) { selection }
        if (unfinished != null) io.execute { remove(unfinished) }
        io.shutdown()
    }

    companion object {
        private const val REQUEST_CODE = 62031
        private const val MAX_ZIP_BYTES = 21 * 1024 * 1024
    }
}
