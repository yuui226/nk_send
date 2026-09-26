package com.ztransfer.crop

import android.app.Activity
import android.app.Instrumentation
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import android.os.SystemClock
import android.view.MotionEvent
import androidx.activity.compose.setContent
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.graphics.asImageBitmap
import com.ztransfer.MainActivity
import com.ztransfer.R
import com.ztransfer.ui.screen.CropEditor
import com.ztransfer.ui.theme.ThemeMode
import com.ztransfer.ui.theme.ZTransferTheme
import java.io.File

class CropEditorInstrumentation : Instrumentation() {
    override fun onCreate(arguments: Bundle?) { super.onCreate(arguments); start() }
    override fun onStart() {
        val result=Bundle()
        var code=Activity.RESULT_CANCELED
        var activity: MainActivity?=null
        try {
            val bitmap=Bitmap.createBitmap(1200,800,Bitmap.Config.ARGB_8888)
            for(y in 0 until bitmap.height) for(x in 0 until bitmap.width) {
                bitmap.setPixel(x,y,Color.rgb(40+x*170/1200,65+y*135/800,105))
            }
            val preview=CropPreview(JpegCropSource(6000,4000,16,8,1),bitmap.asImageBitmap())
            val theme=mutableStateOf(ThemeMode.LIGHT)
            var accepted:JpegCropSelection?=null
            activity=startActivitySync(Intent(targetContext,MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) as MainActivity
            runOnMainSync { activity.setContent {
                ZTransferTheme(themeMode=theme.value) {
                    CropEditor(preview=preview, failed=false, onRetry={}, onCancel={},
                        onConfirm={ selection, _ -> accepted=selection; false }, onFeedback={})
                }
            } }
            waitForIdleSync(); SystemClock.sleep(350)
            screenshot("crop-editor-light.png")
            val screen=uiAutomation.takeScreenshot()
            val w=screen.width.toFloat(); val h=screen.height.toFloat();screen.recycle()
            clickDescription("1:1")
            pinch(w*.5f,h*.5f,w*.10f,w*.23f)
            drag(w*.45f,h*.50f,w*.6f,h*.48f)
            clickDescription(activity.getString(R.string.crop_confirm))
            check(accepted!=null)
            preview.source.validate(checkNotNull(accepted).resolve(preview.source).rect)
            check(accepted!!.resolve(preview.source).rect.width == accepted!!.resolve(preview.source).rect.height)
            check(accepted!!.resolve(preview.source).rect.width < preview.source.width / 2) { "Pinch did not zoom the crop" }
            runOnMainSync { theme.value=ThemeMode.DARK }
            SystemClock.sleep(250)
            screenshot("crop-editor-dark.png")
            uiAutomation.setRotation(android.app.UiAutomation.ROTATION_FREEZE_90)
            SystemClock.sleep(600)
            screenshot("crop-editor-landscape.png")
            clickDescription(activity.getString(R.string.crop_reset))
            clickDescription(activity.getString(R.string.crop_confirm))
            check(accepted!!.resolve(preview.source).rect.width == preview.source.width && accepted!!.resolve(preview.source).rect.height == preview.source.height)
            uiAutomation.setRotation(android.app.UiAutomation.ROTATION_UNFREEZE)
            result.putString("result","PASS: crop editor renders both themes, touch and confirmation; screenshots saved")
            code=Activity.RESULT_OK
        } catch(failure:Throwable) { result.putString("failure",failure.stackTraceToString()) }
        finally { uiAutomation.setRotation(android.app.UiAutomation.ROTATION_UNFREEZE); activity?.let { runOnMainSync { it.finish() } } }
        finish(code,result)
    }
    private fun clickDescription(description:String) {
        fun find(node:android.view.accessibility.AccessibilityNodeInfo?):android.view.accessibility.AccessibilityNodeInfo? {
            if(node==null)return null
            if(node.contentDescription?.toString()==description || node.text?.toString()==description)return node
            for(i in 0 until node.childCount) find(node.getChild(i))?.let{return it}
            return null
        }
        val node=checkNotNull(find(uiAutomation.rootInActiveWindow)){"Missing action $description"}
        val bounds=android.graphics.Rect();node.getBoundsInScreen(bounds)
        val now=SystemClock.uptimeMillis()
        for(action in listOf(MotionEvent.ACTION_DOWN,MotionEvent.ACTION_UP)) {
            val event=MotionEvent.obtain(now,SystemClock.uptimeMillis(),action,bounds.exactCenterX(),bounds.exactCenterY(),0)
            sendPointerSync(event);event.recycle()
        }
        SystemClock.sleep(120)
    }
    private fun drag(x:Float,y:Float,endX:Float,endY:Float) {
        val now=SystemClock.uptimeMillis()
        for(step in 0..12) {
            val action=when(step){0->MotionEvent.ACTION_DOWN;12->MotionEvent.ACTION_UP;else->MotionEvent.ACTION_MOVE}
            val p=step/12f
            val event=MotionEvent.obtain(now,SystemClock.uptimeMillis(),action,x+(endX-x)*p,y+(endY-y)*p,0)
            sendPointerSync(event);event.recycle();SystemClock.sleep(20)
        }
    }
    private fun pinch(x:Float,y:Float,start:Float,end:Float) {
        val down=SystemClock.uptimeMillis()
        val props=Array(2){i->MotionEvent.PointerProperties().apply {id=i;toolType=MotionEvent.TOOL_TYPE_FINGER}}
        fun send(action:Int,count:Int,radius:Float) {
            val coords=Array(count){i->MotionEvent.PointerCoords().apply {this.x=x+if(i==0)-radius else radius;this.y=y;pressure=1f;size=1f}}
            val event=MotionEvent.obtain(down,SystemClock.uptimeMillis(),action,count,props,coords,0,0,1f,1f,0,0,android.view.InputDevice.SOURCE_TOUCHSCREEN,0)
            sendPointerSync(event);event.recycle()
        }
        send(MotionEvent.ACTION_DOWN,1,start)
        send(MotionEvent.ACTION_POINTER_DOWN or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),2,start)
        for(step in 1..12){SystemClock.sleep(20);send(MotionEvent.ACTION_MOVE,2,start+(end-start)*step/12)}
        send(MotionEvent.ACTION_POINTER_UP or (1 shl MotionEvent.ACTION_POINTER_INDEX_SHIFT),2,end)
        send(MotionEvent.ACTION_UP,1,end)
        SystemClock.sleep(120)
    }
    private fun screenshot(name:String) {
        val bitmap=uiAutomation.takeScreenshot()
        File(targetContext.filesDir,name).outputStream().use {bitmap.compress(Bitmap.CompressFormat.PNG,100,it)}
        bitmap.recycle()
    }
}
