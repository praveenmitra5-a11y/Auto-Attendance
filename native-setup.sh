#!/usr/bin/env bash
# native-setup.sh
# Adds "auto check-in even when the app is closed" + PDF export support to the Capacitor Android project.
# Run from the project root, AFTER `npx cap add android` and BEFORE the gradle build step.
# Safe to run more than once.
set -euo pipefail

[ -d android/app ] || { echo "ERROR: android/ folder not found. Run this after 'npx cap add android'."; exit 1; }

MAIN=$(find android/app/src/main/java -name MainActivity.java | head -n1)
[ -n "$MAIN" ] || { echo "ERROR: MainActivity.java not found"; exit 1; }
JAVA_DIR=$(dirname "$MAIN")
PKG=$(grep -m1 -E '^package ' "$MAIN" | sed -E 's/^package ([A-Za-z0-9_.]+);.*/\1/')
echo "App package: $PKG"

# ---------------------------------------------------------------- 1. npm plugins (match Capacitor major)
if [ "${SKIP_NPM:-0}" != "1" ]; then
  CAPV=$(node -p "require('@capacitor/core/package.json').version.split('.')[0]")
  echo "Capacitor major: $CAPV"
  npm install --no-audit --no-fund "@capacitor/filesystem@^${CAPV}" "@capacitor/share@^${CAPV}"
  npm ls @capacitor/local-notifications >/dev/null 2>&1 || npm install --no-audit --no-fund "@capacitor/local-notifications@^${CAPV}"
fi

# ---------------------------------------------------------------- 2. native Java files
cat > "$JAVA_DIR/GeoStore.java" <<'JAVA'
package __PKG__;

import android.annotation.SuppressLint;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.os.Build;
import androidx.core.app.NotificationCompat;
import com.google.android.gms.location.Geofence;
import com.google.android.gms.location.GeofencingClient;
import com.google.android.gms.location.GeofencingRequest;
import com.google.android.gms.location.LocationServices;
import com.google.android.gms.tasks.OnFailureListener;
import com.google.android.gms.tasks.OnSuccessListener;

final class GeoStore {
    static final String PREFS = "attendance_geo";
    static final String CHANNEL = "attendance_checkin";

    private GeoStore() {}

    static SharedPreferences prefs(Context c) {
        return c.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }

    static PendingIntent geofenceIntent(Context c) {
        Intent i = new Intent(c, GeofenceReceiver.class);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= 31) flags |= PendingIntent.FLAG_MUTABLE;
        return PendingIntent.getBroadcast(c, 7001, i, flags);
    }

    @SuppressLint("MissingPermission")
    static void register(Context c, double lat, double lon, float radius,
                         OnSuccessListener<Void> ok, OnFailureListener fail) {
        Geofence g = new Geofence.Builder()
                .setRequestId("office")
                .setCircularRegion(lat, lon, radius)
                .setExpirationDuration(Geofence.NEVER_EXPIRE)
                .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_ENTER)
                .build();
        GeofencingRequest req = new GeofencingRequest.Builder()
                .setInitialTrigger(GeofencingRequest.INITIAL_TRIGGER_ENTER)
                .addGeofence(g)
                .build();
        GeofencingClient client = LocationServices.getGeofencingClient(c);
        com.google.android.gms.tasks.Task<Void> t = client.addGeofences(req, geofenceIntent(c));
        if (ok != null) t.addOnSuccessListener(ok);
        if (fail != null) t.addOnFailureListener(fail);
    }

    static void notifyArrival(Context c, String time) {
        try {
            NotificationManager nm = (NotificationManager) c.getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm == null) return;
            if (Build.VERSION.SDK_INT >= 26) {
                nm.createNotificationChannel(new NotificationChannel(
                        CHANNEL, "Attendance check-in", NotificationManager.IMPORTANCE_DEFAULT));
            }
            NotificationCompat.Builder b = new NotificationCompat.Builder(c, CHANNEL)
                    .setSmallIcon(android.R.drawable.ic_dialog_info)
                    .setContentTitle("Attendance marked")
                    .setContentText("Arrived at office " + time + " - marked Present")
                    .setAutoCancel(true);
            Intent launch = c.getPackageManager().getLaunchIntentForPackage(c.getPackageName());
            if (launch != null) {
                b.setContentIntent(PendingIntent.getActivity(c, 7002, launch,
                        PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
            }
            Notification n = b.build();
            nm.notify(7003, n);
        } catch (Exception ignored) {
        }
    }
}
JAVA

cat > "$JAVA_DIR/GeofenceReceiver.java" <<'JAVA'
package __PKG__;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import com.google.android.gms.location.Geofence;
import com.google.android.gms.location.GeofencingEvent;
import java.util.Calendar;
import java.util.Locale;
import org.json.JSONArray;
import org.json.JSONObject;

public class GeofenceReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        try {
            GeofencingEvent ev = GeofencingEvent.fromIntent(intent);
            if (ev == null || ev.hasError()) return;
            if (ev.getGeofenceTransition() != Geofence.GEOFENCE_TRANSITION_ENTER) return;

            Calendar c = Calendar.getInstance();
            String date = String.format(Locale.US, "%04d-%02d-%02d",
                    c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH));
            String time = String.format(Locale.US, "%02d:%02d",
                    c.get(Calendar.HOUR_OF_DAY), c.get(Calendar.MINUTE));

            SharedPreferences sp = GeoStore.prefs(context);
            if (date.equals(sp.getString("lastDate", ""))) return; // one check-in per day

            JSONArray arr = new JSONArray(sp.getString("pending", "[]"));
            JSONObject o = new JSONObject();
            o.put("date", date);
            o.put("time", time);
            arr.put(o);
            sp.edit().putString("pending", arr.toString()).putString("lastDate", date).commit();

            // Do not pop a notification if the app was opened a moment ago (user is already looking at it)
            if (System.currentTimeMillis() >= sp.getLong("quietUntil", 0L)) {
                GeoStore.notifyArrival(context, time);
            }
        } catch (Exception ignored) {
        }
    }
}
JAVA

cat > "$JAVA_DIR/BootReceiver.java" <<'JAVA'
package __PKG__;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;

/** Geofences are cleared when the phone reboots or the app is updated - arm it again. */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        try {
            SharedPreferences sp = GeoStore.prefs(context);
            if (!sp.getBoolean("enabled", false)) return;
            double lat = Double.parseDouble(sp.getString("lat", ""));
            double lon = Double.parseDouble(sp.getString("lon", ""));
            float radius = sp.getFloat("radius", 150f);
            GeoStore.register(context, lat, lon, radius, null, null);
        } catch (Exception ignored) {
        }
    }
}
JAVA

cat > "$JAVA_DIR/GeofencePlugin.java" <<'JAVA'
package __PKG__;

import android.Manifest;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.PowerManager;
import android.provider.Settings;
import androidx.core.content.ContextCompat;
import com.getcapacitor.JSArray;
import com.getcapacitor.JSObject;
import com.getcapacitor.PermissionState;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;
import com.getcapacitor.annotation.Permission;
import com.getcapacitor.annotation.PermissionCallback;
import com.google.android.gms.location.LocationServices;
import com.google.android.gms.tasks.OnFailureListener;
import com.google.android.gms.tasks.OnSuccessListener;
import java.util.HashSet;
import java.util.Set;
import org.json.JSONArray;
import org.json.JSONObject;

@CapacitorPlugin(
        name = "AttendanceGeofence",
        permissions = {
                @Permission(
                        alias = "location",
                        strings = {
                                Manifest.permission.ACCESS_FINE_LOCATION,
                                Manifest.permission.ACCESS_COARSE_LOCATION
                        })
        })
public class GeofencePlugin extends Plugin {

    @PluginMethod
    public void start(PluginCall call) {
        if (getPermissionState("location") != PermissionState.GRANTED) {
            requestPermissionForAlias("location", call, "locationPermsCallback");
            return;
        }
        doStart(call);
    }

    @PermissionCallback
    private void locationPermsCallback(PluginCall call) {
        if (getPermissionState("location") == PermissionState.GRANTED) {
            doStart(call);
        } else {
            call.reject("Location permission denied");
        }
    }

    private void doStart(final PluginCall call) {
        Double lat = call.getDouble("lat");
        Double lon = call.getDouble("lon");
        Float radius = call.getFloat("radius", 150f);
        if (lat == null || lon == null) {
            call.reject("lat and lon are required");
            return;
        }
        Context c = getContext();
        if (ContextCompat.checkSelfPermission(c, Manifest.permission.ACCESS_FINE_LOCATION)
                != PackageManager.PERMISSION_GRANTED) {
            call.reject("Precise location is needed - choose 'Precise' when Android asks");
            return;
        }
        GeoStore.prefs(c).edit()
                .putBoolean("enabled", true)
                .putString("lat", String.valueOf(lat))
                .putString("lon", String.valueOf(lon))
                .putFloat("radius", radius)
                .putLong("quietUntil", System.currentTimeMillis() + 90000L)
                .apply();
        GeoStore.register(c, lat, lon, radius,
                new OnSuccessListener<Void>() {
                    @Override
                    public void onSuccess(Void v) {
                        call.resolve();
                    }
                },
                new OnFailureListener() {
                    @Override
                    public void onFailure(Exception e) {
                        call.reject("Could not start geofence: " + e.getMessage());
                    }
                });
    }

    @PluginMethod
    public void stop(PluginCall call) {
        Context c = getContext();
        GeoStore.prefs(c).edit().putBoolean("enabled", false).apply();
        try {
            LocationServices.getGeofencingClient(c).removeGeofences(GeoStore.geofenceIntent(c));
        } catch (Exception ignored) {
        }
        call.resolve();
    }

    @PluginMethod
    public void status(PluginCall call) {
        Context c = getContext();
        boolean fine = ContextCompat.checkSelfPermission(c, Manifest.permission.ACCESS_FINE_LOCATION)
                == PackageManager.PERMISSION_GRANTED;
        boolean bg = Build.VERSION.SDK_INT < 29
                || ContextCompat.checkSelfPermission(c, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
                == PackageManager.PERMISSION_GRANTED;
        PowerManager pm = (PowerManager) c.getSystemService(Context.POWER_SERVICE);
        boolean batt = Build.VERSION.SDK_INT < 23
                || (pm != null && pm.isIgnoringBatteryOptimizations(c.getPackageName()));
        JSObject o = new JSObject();
        o.put("location", fine);
        o.put("background", bg);
        o.put("battery", batt);
        o.put("enabled", GeoStore.prefs(c).getBoolean("enabled", false));
        call.resolve(o);
    }

    @PluginMethod
    public void getPending(PluginCall call) {
        JSObject o = new JSObject();
        try {
            o.put("items", new JSArray(GeoStore.prefs(getContext()).getString("pending", "[]")));
        } catch (Exception e) {
            o.put("items", new JSArray());
        }
        call.resolve(o);
    }

    @PluginMethod
    public void clearPending(PluginCall call) {
        try {
            Set<String> done = new HashSet<String>();
            JSArray dates = call.getArray("dates");
            if (dates != null) {
                for (int i = 0; i < dates.length(); i++) done.add(dates.optString(i));
            }
            android.content.SharedPreferences sp = GeoStore.prefs(getContext());
            JSONArray old = new JSONArray(sp.getString("pending", "[]"));
            JSONArray keep = new JSONArray();
            for (int i = 0; i < old.length(); i++) {
                JSONObject it = old.getJSONObject(i);
                if (!done.contains(it.optString("date"))) keep.put(it);
            }
            sp.edit().putString("pending", keep.toString()).apply();
        } catch (Exception ignored) {
        }
        call.resolve();
    }

    @PluginMethod
    public void openAppSettings(PluginCall call) {
        Context c = getContext();
        Intent i = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.fromParts("package", c.getPackageName(), null));
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        c.startActivity(i);
        call.resolve();
    }

    @PluginMethod
    public void openBatterySettings(PluginCall call) {
        Context c = getContext();
        Intent i = new Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS);
        i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        c.startActivity(i);
        call.resolve();
    }
}
JAVA

sed -i "s/__PKG__/${PKG}/g" "$JAVA_DIR"/GeoStore.java "$JAVA_DIR"/GeofenceReceiver.java "$JAVA_DIR"/BootReceiver.java "$JAVA_DIR"/GeofencePlugin.java

# ---------------------------------------------------------------- 3. MainActivity: register the plugin
if ! grep -q "GeofencePlugin" "$MAIN"; then
cat > "$MAIN" <<JAVA
package ${PKG};

import android.os.Bundle;
import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(GeofencePlugin.class);
        super.onCreate(savedInstanceState);
    }
}
JAVA
fi

# ---------------------------------------------------------------- 4. AndroidManifest: permissions + receivers
PKG="$PKG" python3 - <<'PY'
import os
p = 'android/app/src/main/AndroidManifest.xml'
s = open(p, encoding='utf-8').read()
pkg = os.environ['PKG']

perms = ['ACCESS_FINE_LOCATION', 'ACCESS_COARSE_LOCATION', 'ACCESS_BACKGROUND_LOCATION',
         'RECEIVE_BOOT_COMPLETED', 'POST_NOTIFICATIONS']
add = ''.join('    <uses-permission android:name="android.permission.%s" />\n' % x
              for x in perms if ('android.permission.%s"' % x) not in s)
if add:
    s = s.replace('<application', add + '    <application', 1)

recv = ('        <receiver android:name="%s.GeofenceReceiver" android:exported="true" />\n'
        '        <receiver android:name="%s.BootReceiver" android:exported="true">\n'
        '            <intent-filter>\n'
        '                <action android:name="android.intent.action.BOOT_COMPLETED" />\n'
        '                <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />\n'
        '            </intent-filter>\n'
        '        </receiver>\n') % (pkg, pkg)
if 'GeofenceReceiver' not in s:
    s = s.replace('</application>', recv + '    </application>', 1)
open(p, 'w', encoding='utf-8').write(s)
print('AndroidManifest.xml patched')
PY

# ---------------------------------------------------------------- 5. Gradle: Google Play services location
python3 - <<'PY'
import re
p = 'android/app/build.gradle'
s = open(p, encoding='utf-8').read()
if 'play-services-location' not in s:
    s, n = re.subn(r'^dependencies\s*\{', "dependencies {\n    implementation 'com.google.android.gms:play-services-location:21.3.0'", s, count=1, flags=re.M)
    if n == 0:
        raise SystemExit('ERROR: could not find dependencies { } in android/app/build.gradle')
    open(p, 'w', encoding='utf-8').write(s)
print('build.gradle patched')
PY

# ---------------------------------------------------------------- 6. sync
if [ "${SKIP_NPM:-0}" != "1" ]; then
  npx cap sync android
fi
echo "native-setup.sh finished OK"
