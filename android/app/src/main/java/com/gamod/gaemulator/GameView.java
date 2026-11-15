package com.gamod.gaemulator;

import android.content.Context;
import android.graphics.*;
import android.view.MotionEvent;
import android.view.View;

/** The frame and touch coordinates share the same aspect-fit or full screen rectangle. */
final class GameView extends View {
    private Bitmap bitmap;
    private final Paint paint=new Paint();
    private final RectF destination=new RectF();
    private int tab, pointer=-1;
    private boolean fullScreen;
    GameView(Context context) { super(context); setBackgroundColor(Color.BLACK); paint.setFilterBitmap(false); setFocusable(true); }
    void select(int id, Bitmap cached) { release(); tab=id; bitmap=cached; invalidate(); }
    void fullScreen(boolean value) { release();fullScreen=value;invalidate(); }
    Bitmap frame() { return bitmap; }
    void frame(int[] data) {
        if(data==null || data.length<2) return;
        int w=data[0],h=data[1];
        if(w<1 || h<1 || (long)w*h>data.length-2) return;
        if(bitmap==null || bitmap.getWidth()!=w || bitmap.getHeight()!=h) bitmap=Bitmap.createBitmap(w,h,Bitmap.Config.ARGB_8888);
        bitmap.setPixels(data,2,w,0,0,w,h); invalidate();
    }
    private void bounds() {
        destination.setEmpty(); if(bitmap==null) return;
        if(fullScreen) { destination.set(0,0,getWidth(),getHeight());return; }
        float scale=Math.min((float)getWidth()/bitmap.getWidth(),(float)getHeight()/bitmap.getHeight());
        float w=bitmap.getWidth()*scale,h=bitmap.getHeight()*scale;
        destination.set((getWidth()-w)/2,(getHeight()-h)/2,(getWidth()+w)/2,(getHeight()+h)/2);
    }
    @Override protected void onDraw(Canvas canvas) { super.onDraw(canvas); bounds(); if(bitmap!=null) canvas.drawBitmap(bitmap,null,destination,paint); }
    private void send(int type,float x,float y) {
        if(bitmap==null || destination.isEmpty() || tab==0) return;
        int px=Math.max(0,Math.min(bitmap.getWidth()-1,(int)((x-destination.left)*bitmap.getWidth()/destination.width())));
        int py=Math.max(0,Math.min(bitmap.getHeight()-1,(int)((y-destination.top)*bitmap.getHeight()/destination.height())));
        NativeEngine.event(tab,type,px,py,null);
    }
    void release() { if(pointer!=-1) { send(6,lastX,lastY); pointer=-1; } }
    private float lastX,lastY;
    @Override public boolean onTouchEvent(MotionEvent event) {
        bounds(); int action=event.getActionMasked();
        if(action==MotionEvent.ACTION_DOWN) {
            if(bitmap==null || !destination.contains(event.getX(),event.getY())) return false;
            pointer=event.getPointerId(0); lastX=event.getX(); lastY=event.getY(); send(4,lastX,lastY); return true;
        }
        if(pointer==-1) return false;
        int index=event.findPointerIndex(pointer);
        if(index>=0) { lastX=event.getX(index); lastY=event.getY(index); }
        if(action==MotionEvent.ACTION_MOVE) send(5,lastX,lastY);
        else if(action==MotionEvent.ACTION_UP || action==MotionEvent.ACTION_CANCEL ||
                (action==MotionEvent.ACTION_POINTER_UP && event.getPointerId(event.getActionIndex())==pointer)) { release(); performClick(); }
        return true;
    }
    @Override public boolean performClick() { super.performClick(); return true; }
}
