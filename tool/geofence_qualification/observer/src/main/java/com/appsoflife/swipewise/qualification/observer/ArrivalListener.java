package com.appsoflife.swipewise.qualification.observer;

import android.app.Notification;
import android.content.Context;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;
import java.util.HashSet;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;

public final class ArrivalListener extends NotificationListenerService {
    private static ArrivalListener instance;
    private final Set<String> seen = new HashSet<>();

    private static boolean arrival(StatusBarNotification item) {
        return item.getPackageName().equals("com.appsoflife.swipewise.dev") &&
            "swipewise_dwell".equals(item.getNotification().getChannelId());
    }

    private static JSONObject item(StatusBarNotification item) {
        Notification notification = item.getNotification();
        return Trace.object("package", item.getPackageName(), "channel", notification.getChannelId(),
            "tag", item.getTag(), "id", item.getId(), "key", item.getKey(), "post_unix_ms", item.getPostTime(),
            "title", notification.extras.getCharSequence(Notification.EXTRA_TITLE),
            "text", notification.extras.getCharSequence(Notification.EXTRA_TEXT),
            "big_text", notification.extras.getCharSequence(Notification.EXTRA_BIG_TEXT));
    }

    private JSONArray active() {
        JSONArray result = new JSONArray();
        StatusBarNotification[] active = getActiveNotifications();
        if (active != null) {
            for (StatusBarNotification item : active) {
                if (arrival(item)) result.put(item(item));
            }
        }
        return result;
    }

    static void snapshot(Context context) {
        Trace.emit(context, "listener_snapshot", Trace.object("connected", instance != null,
            "active", instance == null ? null : instance.active()));
    }

    @Override public void onListenerConnected() {
        instance = this;
        Trace.emit(this, "listener_connected", Trace.object("active", active()));
    }

    @Override public void onListenerDisconnected() {
        instance = null;
        Trace.emit(this, "listener_disconnected", Trace.object());
    }

    @Override public void onNotificationPosted(StatusBarNotification item) {
        if (!arrival(item)) return;
        String change = seen.add(item.getKey()) ? "post" : "update";
        Trace.emit(this, "listener_post", Trace.object("change", change, "notification", item(item)));
    }

    @Override public void onNotificationRemoved(StatusBarNotification item, RankingMap rankings, int reason) {
        if (!arrival(item)) return;
        seen.remove(item.getKey());
        Trace.emit(this, "listener_remove", Trace.object("notification", item(item), "reason", reason));
    }
}
