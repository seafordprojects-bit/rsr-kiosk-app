package ph.rsr.kiosk;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.provider.Telephony;
import android.telephony.SmsMessage;

/**
 * Build-6 (owner 2026-11-16): the SIM sits inside the locked kiosk tablet, so nobody can read the telco's
 * texts (load received, promo expiring, data low). This receiver keeps ONLY texts from the telco (a name or a
 * short code, see TelcoText) and queues them for the office; a text from a person's number is dropped here and
 * never leaves the tablet. The phone's own Messages app still gets every text as usual.
 */
public class SmsReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context c, Intent i) {
        try {
            if (!Telephony.Sms.Intents.SMS_RECEIVED_ACTION.equals(i.getAction())) return;
            SmsMessage[] parts = Telephony.Sms.Intents.getMessagesFromIntent(i);
            if (parts == null || parts.length == 0) return;
            String from = parts[0].getDisplayOriginatingAddress();
            if (!TelcoText.isTelcoSender(from)) return;          // a person: never stored, never sent
            StringBuilder b = new StringBuilder();
            for (SmsMessage m : parts) if (m != null && m.getDisplayMessageBody() != null) b.append(m.getDisplayMessageBody());
            long at = parts[0].getTimestampMillis() > 0 ? parts[0].getTimestampMillis() : System.currentTimeMillis();
            TextQueue.add(c, from.trim(), TelcoText.clip(TelcoText.maskNumbers(b.toString())), at);
            Core.get(c).sendTextsSoon();
        } catch (Exception ignored) { }
    }
}
