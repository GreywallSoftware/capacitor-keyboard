package com.capacitorjs.plugins.keyboard;

import android.content.Context;
import android.graphics.Rect;
import android.view.View;
import android.view.Window;
import android.view.inputmethod.InputMethodManager;
import android.widget.FrameLayout;
import androidx.annotation.Nullable;
import androidx.appcompat.app.AppCompatActivity;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;
import com.getcapacitor.Bridge;

public class Keyboard {

    interface KeyboardEventListener {
        void onKeyboardEvent(String event, int size);
    }

    private Bridge bridge;
    private AppCompatActivity activity;
    private View rootView;
    private int usableHeightPrevious;
    private FrameLayout.LayoutParams frameLayoutParams;
    private View mChildOfContent;
    private boolean keyboardVisible;
    private int keyboardHeight;

    public void setKeyboardEventListener(@Nullable KeyboardEventListener keyboardEventListener) {
        this.keyboardEventListener = keyboardEventListener;
    }

    @Nullable
    private KeyboardEventListener keyboardEventListener;

    static final String EVENT_KB_WILL_SHOW = "keyboardWillShow";
    static final String EVENT_KB_DID_SHOW = "keyboardDidShow";
    static final String EVENT_KB_WILL_HIDE = "keyboardWillHide";
    static final String EVENT_KB_DID_HIDE = "keyboardDidHide";

    // From android 15 on, we need access to the bridge to get the config to resize the keyboard properly.
    public Keyboard(Bridge bridge, boolean resizeOnFullScreen) {
        this(bridge.getActivity(), resizeOnFullScreen);
        this.bridge = bridge;
    }

    // We may want to deprecate this constructor in the future, but we are keeping it now to keep backward compatibility with cap 7
    public Keyboard(AppCompatActivity activity, boolean resizeOnFullScreen) {
        this.activity = activity;

        //http://stackoverflow.com/a/4737265/1091751 detect if keyboard is showing
        FrameLayout content = activity.getWindow().getDecorView().findViewById(android.R.id.content);
        rootView = content.getRootView();

        // Keyboard state is read from window insets only. Do NOT register a
        // WindowInsetsAnimationCallback anywhere in the hierarchy: as soon as the
        // decor view has one, InsetsController stops running the IME animation on
        // its dedicated InsetsAnimationThread and drives it from the UI thread
        // instead (AOSP InsetsController#applyAnimation:
        // `!hasAnimationCallbacks || skipsCallbacks /* useInsetsAnimationThread */`).
        // In a WebView app the UI thread is at its busiest exactly when an input
        // gains focus (focus dispatch, IME connection, evaluateJavascript, the
        // resize relayout), so the keyboard starts late and stutters behind the
        // caret. Without a callback the system animates the IME off the UI thread.
        //
        // Nothing is lost: with adjustResize, InsetsController lays the window out
        // with the END state for the whole animation, on show and on hide
        // (LAYOUT_INSETS_DURING_ANIMATION_SHOWN / _HIDDEN), so the inset change
        // arrives here when the animation starts — the moment the WebView resizes.
        ViewCompat.setOnApplyWindowInsetsListener(content, (v, insets) -> {
            WindowInsetsCompat rootInsets = ViewCompat.getRootWindowInsets(rootView);
            if (rootInsets == null) return insets;

            boolean showingKeyboard = rootInsets.isVisible(WindowInsetsCompat.Type.ime());

            if (resizeOnFullScreen) {
                possiblyResizeChildOfContent(showingKeyboard);
            }

            notifyKeyboardState(showingKeyboard, rootInsets.getInsets(WindowInsetsCompat.Type.ime()).bottom);

            v.onApplyWindowInsets(insets.toWindowInsets());

            return insets;
        });

        mChildOfContent = content.getChildAt(0);
        frameLayoutParams = (FrameLayout.LayoutParams) mChildOfContent.getLayoutParams();
    }

    /**
     * Emit keyboard events when the IME visibility or height actually changes.
     * Insets are re-applied for many unrelated reasons (system bars, rotation,
     * SystemBars padding), so repeats are dropped.
     *
     * The "will" and "did" events are emitted together: the layout they describe
     * is already final when the insets arrive (see the constructor), so a
     * `keyboardDidShow` handler that measures or scrolls sees the resized
     * viewport. This matches the pre-WindowInsetsAnimation Android implementation.
     */
    private void notifyKeyboardState(boolean imeVisible, int imeHeightPx) {
        // At the start of a hide the layout already uses the hidden (zero) inset
        // while the IME may still report visible; a zero-height keyboard is hidden.
        boolean visible = imeVisible && imeHeightPx > 0;
        float density = activity.getResources().getDisplayMetrics().density;
        int height = visible ? Math.round(imeHeightPx / density) : 0;
        if (visible == keyboardVisible && height == keyboardHeight) {
            return;
        }
        keyboardVisible = visible;
        keyboardHeight = height;

        if (keyboardEventListener == null) {
            return;
        }
        if (visible) {
            keyboardEventListener.onKeyboardEvent(EVENT_KB_WILL_SHOW, height);
            keyboardEventListener.onKeyboardEvent(EVENT_KB_DID_SHOW, height);
        } else {
            keyboardEventListener.onKeyboardEvent(EVENT_KB_WILL_HIDE, 0);
            keyboardEventListener.onKeyboardEvent(EVENT_KB_DID_HIDE, 0);
        }
    }

    public void show() {
        ((InputMethodManager) activity.getSystemService(Context.INPUT_METHOD_SERVICE)).showSoftInput(activity.getCurrentFocus(), 0);
    }

    public boolean hide() {
        InputMethodManager inputManager = (InputMethodManager) activity.getSystemService(Context.INPUT_METHOD_SERVICE);
        View v = activity.getCurrentFocus();
        if (v == null) {
            return false;
        } else {
            inputManager.hideSoftInputFromWindow(v.getWindowToken(), InputMethodManager.HIDE_NOT_ALWAYS);
            return true;
        }
    }

    private void possiblyResizeChildOfContent(boolean keyboardShown) {
        if (isSystemBarsPluginPresent()) {
            // SystemBars handles the inset sizing for visible keyboards
            return;
        }

        int usableHeightNow = keyboardShown ? computeUsableHeight() : -1;
        if (usableHeightPrevious != usableHeightNow) {
            frameLayoutParams.height = usableHeightNow;
            mChildOfContent.requestLayout();
            usableHeightPrevious = usableHeightNow;
        }
    }

    private int computeUsableHeight() {
        Rect r = new Rect();
        mChildOfContent.getWindowVisibleDisplayFrame(r);
        return isOverlays() ? r.bottom : r.height();
    }

    private static boolean isSystemBarsPluginPresent() {
        try {
            Class.forName("com.getcapacitor.plugin.SystemBars");
            return true;
        } catch (ClassNotFoundException e) {
            return false;
        }
    }

    @SuppressWarnings("deprecation")
    private boolean isOverlays() {
        final Window window = activity.getWindow();
        return (
            (window.getDecorView().getSystemUiVisibility() & View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN) == View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
        );
    }
}
