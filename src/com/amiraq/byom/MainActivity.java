package com.amiraq.byom;

import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.os.ParcelFileDescriptor;
import android.util.Log;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.IOException;

public class MainActivity extends Activity {

    private static final int PICK_MODEL_REQUEST = 1;
    private static final int MAX_OUTPUT_TOKENS = 96;

    private TextView statusText;
    private TextView outputText;
    private EditText promptInput;
    private Button mountBtn;
    private Button generateBtn;
    private volatile boolean modelLoaded = false;

    static {
        System.loadLibrary("llama_engine");
    }

    public native String loadModelFromFd(int fd);

    public native String generateText(String prompt, int maxTokens);

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        ScrollView scrollView = new ScrollView(this);
        scrollView.setFillViewport(true);
        scrollView.setBackgroundColor(Color.parseColor("#0A0A0A"));

        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        layout.setBackgroundColor(Color.parseColor("#0A0A0A"));
        layout.setGravity(Gravity.CENTER_HORIZONTAL);
        layout.setPadding(32, 48, 32, 48);

        LinearLayout.LayoutParams fullWidth =
                new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        fullWidth.bottomMargin = 24;

        statusText = new TextView(this);
        statusText.setText("BYOM EDGE AI\n\n[ LOAD A GGUF MODEL ]");
        statusText.setTextColor(Color.parseColor("#F5F5F5"));
        statusText.setGravity(Gravity.CENTER);
        statusText.setTextSize(16f);
        statusText.setPadding(0, 0, 0, 24);

        promptInput = new EditText(this);
        promptInput.setHint("Type a prompt for the model...");
        promptInput.setHintTextColor(Color.parseColor("#7A7A7A"));
        promptInput.setTextColor(Color.parseColor("#F5F5F5"));
        promptInput.setBackgroundColor(Color.parseColor("#161616"));
        promptInput.setGravity(Gravity.TOP | Gravity.START);
        promptInput.setMinLines(4);
        promptInput.setPadding(28, 28, 28, 28);

        mountBtn = new Button(this);
        mountBtn.setText("MOUNT GGUF MODEL");
        mountBtn.setBackgroundColor(Color.parseColor("#F5F5F5"));
        mountBtn.setTextColor(Color.parseColor("#0A0A0A"));

        generateBtn = new Button(this);
        generateBtn.setText("GENERATE RESPONSE");
        generateBtn.setBackgroundColor(Color.parseColor("#C8FF5A"));
        generateBtn.setTextColor(Color.parseColor("#0A0A0A"));
        setButtonState(generateBtn, false);

        outputText = new TextView(this);
        outputText.setText("Load a GGUF model, then ask it something.");
        outputText.setTextColor(Color.parseColor("#F5F5F5"));
        outputText.setBackgroundColor(Color.parseColor("#111111"));
        outputText.setPadding(28, 28, 28, 28);
        outputText.setMinLines(6);

        mountBtn.setOnClickListener(v -> openModelPicker());
        generateBtn.setOnClickListener(v -> generateResponse());

        layout.addView(statusText, fullWidth);
        layout.addView(promptInput, fullWidth);
        layout.addView(mountBtn, fullWidth);
        layout.addView(generateBtn, fullWidth);
        layout.addView(outputText, fullWidth);

        scrollView.addView(layout);
        setContentView(scrollView);
    }

    private void openModelPicker() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION);
        startActivityForResult(intent, PICK_MODEL_REQUEST);
    }

    private void generateResponse() {
        if (!modelLoaded) {
            statusText.setText("ERROR: Load a GGUF model first.");
            return;
        }

        final String prompt = promptInput.getText().toString().trim();
        if (prompt.isEmpty()) {
            statusText.setText("ERROR: Enter a prompt first.");
            return;
        }

        setButtonState(generateBtn, false);
        setButtonState(mountBtn, false);
        statusText.setText("[ GENERATING RESPONSE ]");
        outputText.setText("Running inference...");

        new Thread(() -> {
            final String result = generateText(prompt, MAX_OUTPUT_TOKENS);

            runOnUiThread(() -> {
                setButtonState(mountBtn, true);
                setButtonState(generateBtn, modelLoaded);

                if (result == null || result.trim().isEmpty()) {
                    statusText.setText("ERROR: Model returned an empty response.");
                    outputText.setText("No output.");
                    return;
                }

                if (result.startsWith("[ERROR]")) {
                    statusText.setText(result);
                    outputText.setText("Inference failed.");
                    return;
                }

                statusText.setText("[ RESPONSE READY ]");
                outputText.setText(result.trim());
            });
        }).start();
    }

    private void setButtonState(Button button, boolean enabled) {
        button.setEnabled(enabled);
        button.setAlpha(enabled ? 1f : 0.45f);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != PICK_MODEL_REQUEST || resultCode != Activity.RESULT_OK || data == null || data.getData() == null) {
            return;
        }

        Uri uri = data.getData();
        try {
            final int grantFlags = data.getFlags() &
                    (Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
            if (grantFlags != 0) {
                getContentResolver().takePersistableUriPermission(uri, grantFlags);
            }
        } catch (SecurityException | IllegalArgumentException ignored) {
            // Some providers do not grant persistable permissions; runtime access still works.
        }

        statusText.setText("Mounting Model...");
        outputText.setText("Loading GGUF into the native engine...");
        setButtonState(mountBtn, false);
        setButtonState(generateBtn, false);
        modelLoaded = false;

        new Thread(() -> {
            String errorMessage = null;

            try (ParcelFileDescriptor pfd = getContentResolver().openFileDescriptor(uri, "r")) {
                if (pfd == null) {
                    errorMessage = "ERROR: Failed to open selected file.";
                } else {
                    errorMessage = loadModelFromFd(pfd.getFd());
                }
            } catch (IOException e) {
                errorMessage = "ERROR: " + e.getMessage();
                Log.e("BYOM_Java", "Failed to load model", e);
            }

            final String finalErrorMessage = errorMessage;
            runOnUiThread(() -> {
                setButtonState(mountBtn, true);

                if (finalErrorMessage == null) {
                    modelLoaded = true;
                    statusText.setText("[ MODEL READY FOR INFERENCE ]");
                    outputText.setText("Model loaded. Enter a prompt and tap GENERATE RESPONSE.");
                    setButtonState(generateBtn, true);
                } else {
                    statusText.setText(finalErrorMessage);
                    outputText.setText(finalErrorMessage);
                }
            });
        }).start();
    }
}
