package ph.rsr.kiosk;

/** Words for the hidden-settings passcode box (5 taps top-right). Plain Java so it is tested without Android. */
final class PasscodeText {
    private PasscodeText() { }

    /** Message after a wrong passcode. triesLeft = tries before the 5-minute wait (0 = the wait just started). */
    static String wrong(int triesLeft) {
        if (!canRetry(triesLeft)) return "Wrong passcode. Too many wrong tries.\n\nWait 5 minutes, then try again.";
        return "Wrong passcode. Please try again.\n\n" + triesLeft + (triesLeft == 1 ? " try" : " tries")
                + " left before a 5-minute wait.";
    }

    static boolean canRetry(int triesLeft) { return triesLeft > 0; }

    /** Eye button: the passcode is hidden until the owner taps Show. */
    static String eyeLabel(boolean shown) { return shown ? "Hide" : "Show"; }
}
