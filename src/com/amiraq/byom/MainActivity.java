package com.amiraq.byom;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.graphics.Color;
import android.view.Gravity;
import android.util.Log;
import java.io.IOException;

public class MainActivity extends Activity {

    private static final int PICK_MODEL_REQUEST = 1;
    private TextView statusText;

    static {
        System.loadLibrary("llama_engine");
    }

    public native void loadModelFromFd(int fd);

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // بناء تخطيط وحشي راقٍ
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setBackgroundColor(Color.parseColor("#0A0A0A"));
        layout.setGravity(Gravity.CENTER);
        layout.setPadding(32, 32, 32, 32);

        statusText = new TextView(this);
        statusText.setText("BYOM EDGE AI\n\n[ SYSTEM READY ]\n");
        statusText.setTextColor(Color.parseColor("#F5F5F5"));
        statusText.setGravity(Gravity.CENTER);
        statusText.setTextSize(16f);

        Button mountBtn = new Button(this);
        mountBtn.setText("MOUNT GGUF MODEL");
        mountBtn.setBackgroundColor(Color.parseColor("#F5F5F5"));
        mountBtn.setTextColor(Color.parseColor("#0A0A0A"));

        mountBtn.setOnClickListener(v -> {
            // فتح منتقي ملفات النظام الآمن
            Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
            intent.addCategory(Intent.CATEGORY_OPENABLE);
            intent.setType("*/*"); // GGUF ليس له MIME type رسمي
            startActivityForResult(intent, PICK_MODEL_REQUEST);
        });

        layout.addView(statusText);
        layout.addView(mountBtn);
        setContentView(layout);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == PICK_MODEL_REQUEST && resultCode == Activity.RESULT_OK) {
            if (data != null && data.getData() != null) {
                Uri uri = data.getData();
                statusText.setText("Mounting Model...\nURI: " + uri.getPath());

                try {
                    // فتح الملف واستخراج المعرف الرقمي (File Descriptor)
                    ParcelFileDescriptor pfd = getContentResolver().openFileDescriptor(uri, "r");
                    if (pfd != null) {
                        int fd = pfd.getFd();
                        // إرسال المعرف إلى محرك C++
                        loadModelFromFd(fd);
                        statusText.setText("[ MODEL MOUNTED SECURELY IN C++ ENGINE ]");
                        // لا نغلق pfd هنا لكي لا ينقطع الاتصال أثناء استخدام النموذج
                    }
                } catch (IOException e) {
                    statusText.setText("ERROR: " + e.getMessage());
                    Log.e("BYOM_Java", "Failed to open FD", e);
                }
            }
        }
    }
}
