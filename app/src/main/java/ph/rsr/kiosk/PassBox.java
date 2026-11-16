package ph.rsr.kiosk;

import android.content.Context;
import android.text.InputType;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;

/** A number passcode box with an eye button (Show / Hide) like a sign-in page, so the owner can check
 *  the digits before pressing Open or Save. Hidden every time it is opened. */
final class PassBox {
    final LinearLayout view;
    final EditText input;
    private boolean shown;

    PassBox(Context c, String hint) {
        float d = c.getResources().getDisplayMetrics().density;
        view = new LinearLayout(c);
        view.setOrientation(LinearLayout.HORIZONTAL);
        view.setGravity(Gravity.CENTER_VERTICAL);
        input = new EditText(c);
        input.setHint(hint);
        input.setTextSize(22);
        input.setSingleLine(true);
        apply();
        view.addView(input, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        Button eye = new Button(c);
        eye.setAllCaps(false);
        eye.setTextSize(16);
        eye.setText("👁 " + PasscodeText.eyeLabel(false));
        eye.setMinWidth(Math.round(96 * d));
        eye.setMinHeight(Math.round(56 * d));
        eye.setContentDescription("Show or hide passcode");
        eye.setOnClickListener(v -> {
            shown = !shown;
            apply();
            eye.setText("👁 " + PasscodeText.eyeLabel(shown));
        });
        view.addView(eye, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
    }

    private void apply() {
        int sel = input.getSelectionEnd();
        input.setInputType(InputType.TYPE_CLASS_NUMBER
                | (shown ? InputType.TYPE_NUMBER_VARIATION_NORMAL : InputType.TYPE_NUMBER_VARIATION_PASSWORD));
        input.setSelection(Math.max(0, Math.min(sel < 0 ? input.length() : sel, input.length())));
    }

    String text() { return input.getText().toString(); }
}
