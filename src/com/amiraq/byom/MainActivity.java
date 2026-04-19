package com.amiraq.byom;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;
import android.graphics.Color;
import android.view.Gravity;

public class MainActivity extends Activity {

    static {
        System.loadLibrary("llama_engine");
    }

    public native void loadModelFromFd(int fd);

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        TextView terminalView = new TextView(this);
        terminalView.setText("BYOM EDGE AI SYSTEM\n\n[ STATUS: AWAITING MODEL OVERRIDE ]");
        terminalView.setTextColor(Color.parseColor("#F5F5F5"));
        terminalView.setBackgroundColor(Color.parseColor("#0A0A0A"));
        terminalView.setGravity(Gravity.CENTER);
        terminalView.setTextSize(16f);

        setContentView(terminalView);
    }
}
