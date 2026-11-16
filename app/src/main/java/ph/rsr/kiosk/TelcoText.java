package ph.rsr.kiosk;

/**
 * Texts that arrive on the kiosk tablet's SIM (build-6, owner 2026-11-16): only texts from the telco
 * (a name like "DITO" / "GOMO", or a short code like 8080) may leave the tablet - they tell us about loads,
 * expiry and low data. A text from a person (a mobile or landline number) is never sent anywhere.
 * Plain Java (tested in test/TelcoTextTest.java).
 */
final class TelcoText {
    private TelcoText() { }

    static boolean isTelcoSender(String sender) {
        if (sender == null) return false;
        String s = sender.trim();
        if (s.isEmpty()) return false;
        for (int i = 0; i < s.length(); i++) if (Character.isLetter(s.charAt(i))) return true;   // a name = telco / service
        String digits = s.replaceAll("[^0-9]", "");
        return !digits.isEmpty() && digits.length() <= 6;   // short code; 7+ digits = a person's number
    }

    static String clip(String body) {
        if (body == null) return "";
        return body.length() > 1000 ? body.substring(0, 1000) : body;
    }
}
