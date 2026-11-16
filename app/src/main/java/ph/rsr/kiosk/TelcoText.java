package ph.rsr.kiosk;

/**
 * Texts that arrive on the kiosk tablet's SIM (build-6, owner 2026-11-16): only texts from the telco
 * (a name like "DITO" / "GOMO", or a short code like 8080) may leave the tablet - they tell us about loads,
 * expiry and low data. A text from a person (a mobile or landline number) is never sent anywhere.
 * Plain Java (tested in test/TelcoTextTest.java).
 */
final class TelcoText {
    private TelcoText() { }

    private static final java.util.regex.Pattern TELCO =
            java.util.regex.Pattern.compile("(?i)(dito|gomo|globe|\\btm\\b|smart|\\btnt\\b|\\bsun\\b)");

    /** Only the telco: its name (DITO, GOMO, Globe, TM, Smart, TNT, Sun) or a 3-5 digit short code. A person,
     *  a bank / GCash code or any other sender is never sent (review 2026-11-16: names alone were too wide). */
    static boolean isTelcoSender(String sender) {
        if (sender == null) return false;
        String s = sender.trim();
        if (s.isEmpty()) return false;
        if (TELCO.matcher(s).find()) return true;
        return s.matches("[0-9]{3,5}");
    }

    /** A person's number inside a telco text (missed call, pasaload) is masked before it leaves the tablet. */
    static String maskNumbers(String body) {
        if (body == null) return "";
        return body.replaceAll("(\\+?63|0)?9[0-9]{2}[ -]?[0-9]{3}[ -]?[0-9]{4}", "09*********");
    }

    static String clip(String body) {
        if (body == null) return "";
        return body.length() > 1000 ? body.substring(0, 1000) : body;
    }
}
