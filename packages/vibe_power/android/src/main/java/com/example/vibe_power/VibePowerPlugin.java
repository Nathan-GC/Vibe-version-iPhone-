package com.example.vibe_power;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;
import android.os.PowerManager;
import android.view.WindowManager;

import androidx.annotation.NonNull;

import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Mode Focus de Vibe Player : maintien de l'écran allumé et suivi du mode
 * économie d'énergie. Voir lib/vibe_power.dart côté Dart.
 */
public class VibePowerPlugin implements FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler,
        EventChannel.StreamHandler {

    private MethodChannel methods;
    private EventChannel powerSaveEvents;
    private Context context;
    private Activity activity;
    private BroadcastReceiver powerSaveReceiver;
    // Dernier état demandé par Dart, réappliqué à chaque (re)liaison à une
    // activité (rotation, recréation).
    private boolean keepScreenOn = false;

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        context = binding.getApplicationContext();
        methods = new MethodChannel(binding.getBinaryMessenger(), "vibe_power/methods");
        methods.setMethodCallHandler(this);
        powerSaveEvents = new EventChannel(binding.getBinaryMessenger(), "vibe_power/power_save");
        powerSaveEvents.setStreamHandler(this);
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
        methods.setMethodCallHandler(null);
        powerSaveEvents.setStreamHandler(null);
        stopListening();
        context = null;
    }

    @Override
    public void onAttachedToActivity(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
        applyKeepScreenOn();
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        activity = null;
    }

    @Override
    public void onReattachedToActivityForConfigChanges(@NonNull ActivityPluginBinding binding) {
        activity = binding.getActivity();
        applyKeepScreenOn();
    }

    @Override
    public void onDetachedFromActivity() {
        activity = null;
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "setKeepScreenOn":
                keepScreenOn = Boolean.TRUE.equals(call.arguments);
                applyKeepScreenOn();
                result.success(null);
                break;
            case "isPowerSaveMode":
                result.success(isPowerSaveMode());
                break;
            default:
                result.notImplemented();
        }
    }

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        stopListening();
        powerSaveReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context receiverContext, Intent intent) {
                events.success(isPowerSaveMode());
            }
        };
        IntentFilter filter = new IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED);
        // Diffusion système : RECEIVER_NOT_EXPORTED suffit (et est exigé par
        // Android 14+ pour tout récepteur enregistré dynamiquement).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(powerSaveReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            context.registerReceiver(powerSaveReceiver, filter);
        }
    }

    @Override
    public void onCancel(Object arguments) {
        stopListening();
    }

    private void stopListening() {
        if (powerSaveReceiver != null && context != null) {
            context.unregisterReceiver(powerSaveReceiver);
        }
        powerSaveReceiver = null;
    }

    private boolean isPowerSaveMode() {
        if (context == null) return false;
        PowerManager powerManager = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        return powerManager != null && powerManager.isPowerSaveMode();
    }

    private void applyKeepScreenOn() {
        final Activity current = activity;
        if (current == null) return;
        current.runOnUiThread(() -> {
            if (keepScreenOn) {
                current.getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            } else {
                current.getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
            }
        });
    }
}
