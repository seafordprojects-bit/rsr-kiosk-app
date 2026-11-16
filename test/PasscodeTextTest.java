package ph.rsr.kiosk;

/** Plain-Java test for the hidden-settings passcode messages (no Android needed). */
public class PasscodeTextTest {
    static int pass, fail;
    static void ok(boolean c, String m) { if (c) pass++; else { fail++; System.out.println("FAIL " + m); } }

    public static void main(String[] a) {
        // Wrong passcode: tell the owner it was wrong, and how many tries are left before the 5-minute wait.
        ok("Wrong passcode. Please try again.\n\n4 tries left before a 5-minute wait.".equals(PasscodeText.wrong(4)), "4 left");
        ok("Wrong passcode. Please try again.\n\n1 try left before a 5-minute wait.".equals(PasscodeText.wrong(1)), "1 left: singular");
        ok("Wrong passcode. Too many wrong tries.\n\nWait 5 minutes, then try again.".equals(PasscodeText.wrong(0)), "0 left: locked now");
        ok(PasscodeText.wrong(-3).equals(PasscodeText.wrong(0)), "negative = locked");
        ok(!PasscodeText.canRetry(0) && PasscodeText.canRetry(1), "Try again button only when tries are left");
        // Eye button: hidden by default, toggles label
        ok("Show".equals(PasscodeText.eyeLabel(false)) && "Hide".equals(PasscodeText.eyeLabel(true)), "eye labels");
        System.out.println(pass + " passed, " + fail + " failed");
        if (fail > 0) System.exit(1);
    }
}
