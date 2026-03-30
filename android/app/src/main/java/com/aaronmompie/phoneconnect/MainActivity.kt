package com.aaronmompie.phoneconnect

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.spring
import androidx.compose.animation.fadeIn
import androidx.compose.animation.scaleIn
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.aaronmompie.phoneconnect.ui.theme.PhoneConnectTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            PhoneConnectTheme {
                OnboardingScreen()
            }
        }
    }
}

@Composable
fun OnboardingScreen() {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    
    var isBatteryOptimized by remember { mutableStateOf(isIgnoringBatteryOptimizations(context)) }
    var isNotificationAccessGranted by remember { mutableStateOf(isNotificationListenerEnabled(context)) }
    var isGalleryAccessGranted by remember { mutableStateOf(isGalleryPermissionGranted(context)) }
    var isPhoneAccessGranted by remember { mutableStateOf(isPhonePermissionGranted(context)) }
    var isCameraAccessGranted by remember { mutableStateOf(isCameraPermissionGranted(context)) }
    var isSmsAccessGranted by remember { mutableStateOf(isSmsPermissionGranted(context)) }
    var isPostNotificationsGranted by remember { mutableStateOf(isPostNotificationsPermissionGranted(context)) }
    var isNearbyDevicesGranted by remember { mutableStateOf(isNearbyDevicesPermissionGranted(context)) }
    var isMicrophoneGranted by remember { mutableStateOf(isMicrophonePermissionGranted(context)) }
    var isOverlayGranted by remember { mutableStateOf(isOverlayPermissionGranted(context)) }
    var isLocationGranted by remember { mutableStateOf(isLocationPermissionGranted(context)) }

    // Check permissions whenever the app is resumed
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                isBatteryOptimized = isIgnoringBatteryOptimizations(context)
                isNotificationAccessGranted = isNotificationListenerEnabled(context)
                isGalleryAccessGranted = isGalleryPermissionGranted(context)
                isPhoneAccessGranted = isPhonePermissionGranted(context)
                isCameraAccessGranted = isCameraPermissionGranted(context)
                isSmsAccessGranted = isSmsPermissionGranted(context)
                isPostNotificationsGranted = isPostNotificationsPermissionGranted(context)
                isNearbyDevicesGranted = isNearbyDevicesPermissionGranted(context)
                isMicrophoneGranted = isMicrophonePermissionGranted(context)
                isOverlayGranted = isOverlayPermissionGranted(context)
                isLocationGranted = isLocationPermissionGranted(context)
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
        }
    }

    val allPermissionsGranted = isBatteryOptimized && 
            isNotificationAccessGranted && 
            isGalleryAccessGranted && 
            isPhoneAccessGranted && 
            isCameraAccessGranted &&
            isSmsAccessGranted &&
            isPostNotificationsGranted &&
            isNearbyDevicesGranted &&
            isMicrophoneGranted &&
            isOverlayGranted &&
            isLocationGranted

    Surface(
        modifier = Modifier.fillMaxSize(),
        color = MaterialTheme.colorScheme.background
    ) {
        if (allPermissionsGranted) {
            SuccessScreen()
        } else {
            OnboardingPager(
                isBatteryOptimized = isBatteryOptimized,
                isNotificationAccessGranted = isNotificationAccessGranted,
                isGalleryAccessGranted = isGalleryAccessGranted,
                isPhoneAccessGranted = isPhoneAccessGranted,
                isCameraAccessGranted = isCameraAccessGranted,
                isSmsAccessGranted = isSmsAccessGranted,
                isPostNotificationsGranted = isPostNotificationsGranted,
                isNearbyDevicesGranted = isNearbyDevicesGranted,
                isMicrophoneGranted = isMicrophoneGranted,
                isOverlayGranted = isOverlayGranted,
                isLocationGranted = isLocationGranted,
                onGalleryGranted = { isGalleryAccessGranted = true },
                onPhoneGranted = { isPhoneAccessGranted = true },
                onCameraGranted = { isCameraAccessGranted = true },
                onSmsGranted = { isSmsAccessGranted = true },
                onPostNotificationsGranted = { isPostNotificationsGranted = true },
                onNearbyDevicesGranted = { isNearbyDevicesGranted = true },
                onMicrophoneGranted = { isMicrophoneGranted = true },
                onLocationGranted = { isLocationGranted = true }
            )
        }
    }
}

@Composable
fun OnboardingPager(
    isBatteryOptimized: Boolean,
    isNotificationAccessGranted: Boolean,
    isGalleryAccessGranted: Boolean,
    isPhoneAccessGranted: Boolean,
    isCameraAccessGranted: Boolean,
    isSmsAccessGranted: Boolean,
    isPostNotificationsGranted: Boolean,
    isNearbyDevicesGranted: Boolean,
    isMicrophoneGranted: Boolean,
    isOverlayGranted: Boolean,
    isLocationGranted: Boolean,
    onGalleryGranted: () -> Unit,
    onPhoneGranted: () -> Unit,
    onCameraGranted: () -> Unit,
    onSmsGranted: () -> Unit,
    onPostNotificationsGranted: () -> Unit,
    onNearbyDevicesGranted: () -> Unit,
    onMicrophoneGranted: () -> Unit,
    onLocationGranted: () -> Unit
) {
    val pagerState = rememberPagerState(pageCount = { 11 })
    
    val galleryLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        if (permissions.values.all { it }) onGalleryGranted()
    }

    val phoneLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        if (permissions.values.all { it }) onPhoneGranted()
    }

    val cameraLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        if (isGranted) onCameraGranted()
    }

    val smsLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        if (permissions.values.all { it }) onSmsGranted()
    }

    val postNotificationsLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        if (isGranted) onPostNotificationsGranted()
    }

    val nearbyDevicesLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        if (permissions.values.all { it }) onNearbyDevicesGranted()
    }

    val microphoneLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { isGranted ->
        if (isGranted) onMicrophoneGranted()
    }

    val locationLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { permissions ->
        if (permissions.values.all { it }) onLocationGranted()
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .statusBarsPadding()
            .navigationBarsPadding()
    ) {
        HorizontalPager(
            state = pagerState,
            modifier = Modifier.weight(1f),
            verticalAlignment = Alignment.CenterVertically
        ) { page ->
            when (page) {
                0 -> PermissionStep(
                    icon = Icons.Rounded.BatterySaver,
                    title = "Stay Connected",
                    description = "Phone Connect needs to run in the background to maintain a stable connection with your Mac.",
                    buttonText = if (isBatteryOptimized) "Permission Granted" else "Disable Optimization",
                    isEnabled = !isBatteryOptimized,
                    onAction = { launchBatterySettings(it) }
                )
                1 -> PermissionStep(
                    icon = Icons.Rounded.NotificationsActive,
                    title = "Sync Alerts",
                    description = "Allow access to notifications so we can instantly forward your phone's alerts to your desktop.",
                    buttonText = if (isNotificationAccessGranted) "Access Granted" else "Grant Access",
                    isEnabled = !isNotificationAccessGranted,
                    onAction = { launchNotificationSettings(it) }
                )
                2 -> PermissionStep(
                    icon = Icons.Rounded.Bluetooth,
                    title = "Pair with Mac",
                    description = "Pair this phone with your Mac via Bluetooth. This is required for call audio routing — without pairing, you can't route call audio to your Mac.",
                    buttonText = if (isNearbyDevicesGranted) "Open Bluetooth Settings" else "Enable Bluetooth",
                    isEnabled = true,
                    onAction = {
                        if (!isNearbyDevicesGranted && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                            nearbyDevicesLauncher.launch(arrayOf(
                                Manifest.permission.BLUETOOTH_SCAN,
                                Manifest.permission.BLUETOOTH_ADVERTISE,
                                Manifest.permission.BLUETOOTH_CONNECT
                            ))
                        } else {
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) onNearbyDevicesGranted()
                            it.startActivity(Intent(android.provider.Settings.ACTION_BLUETOOTH_SETTINGS))
                        }
                    }
                )
                3 -> PermissionStep(
                    icon = Icons.Rounded.WebAsset,
                    title = "Overlay Access",
                    description = "Allow the app to display important alerts and tools on top of other apps for quick access.",
                    buttonText = if (isOverlayGranted) "Overlay Active" else "Enable Overlay",
                    isEnabled = !isOverlayGranted,
                    onAction = { launchOverlaySettings(it) }
                )
                4 -> PermissionStep(
                    icon = Icons.Rounded.Mic,
                    title = "Audio Bridge",
                    description = "Transfer call audio and your voice to your Mac speakers and microphone seamlessly.",
                    buttonText = if (isMicrophoneGranted) "Audio Linked" else "Link Audio",
                    isEnabled = !isMicrophoneGranted,
                    onAction = {
                        microphoneLauncher.launch(Manifest.permission.RECORD_AUDIO)
                    }
                )
                5 -> PermissionStep(
                    icon = Icons.Rounded.LocationOn,
                    title = "Location Sync",
                    description = "Enable Find My Phone features and location-based triggers directly from your Mac desktop.",
                    buttonText = if (isLocationGranted) "Location Linked" else "Share Location",
                    isEnabled = !isLocationGranted,
                    onAction = {
                        locationLauncher.launch(arrayOf(
                            Manifest.permission.ACCESS_FINE_LOCATION,
                            Manifest.permission.ACCESS_COARSE_LOCATION
                        ))
                    }
                )
                6 -> PermissionStep(
                    icon = Icons.Rounded.PhotoLibrary,
                    title = "Gallery Access",
                    description = "Share your photos and videos seamlessly between your Android device and your Mac desktop.",
                    buttonText = if (isGalleryAccessGranted) "Gallery Linked" else "Link Gallery",
                    isEnabled = !isGalleryAccessGranted,
                    onAction = {
                        val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
                        } else {
                            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
                        }
                        galleryLauncher.launch(permissions)
                    }
                )
                7 -> PermissionStep(
                    icon = Icons.Rounded.Call,
                    title = "Calls & Logs",
                    description = "Detect ongoing calls, view history and make calls directly from your Mac desktop.",
                    buttonText = if (isPhoneAccessGranted) "Phone Connected" else "Connect Phone",
                    isEnabled = !isPhoneAccessGranted,
                    onAction = {
                        val phonePerms = mutableListOf(
                            Manifest.permission.CALL_PHONE,
                            Manifest.permission.READ_CONTACTS,
                            Manifest.permission.READ_CALL_LOG,
                            Manifest.permission.WRITE_CALL_LOG,
                            Manifest.permission.READ_PHONE_STATE
                        )
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            phonePerms.add(Manifest.permission.ANSWER_PHONE_CALLS)
                        }
                        phoneLauncher.launch(phonePerms.toTypedArray())
                    }
                )
                8 -> PermissionStep(
                    icon = Icons.Rounded.Sms,
                    title = "Sms Sync",
                    description = "Read, receive and send SMS messages directly from your Mac desktop.",
                    buttonText = if (isSmsAccessGranted) "SMS Synced" else "Sync SMS",
                    isEnabled = !isSmsAccessGranted,
                    onAction = {
                        smsLauncher.launch(arrayOf(
                            Manifest.permission.READ_SMS,
                            Manifest.permission.RECEIVE_SMS,
                            Manifest.permission.SEND_SMS
                        ))
                    }
                )
                9 -> PermissionStep(
                    icon = Icons.Rounded.PhotoCamera,
                    title = "Camera Access",
                    description = "Use your phone's high-quality camera as a webcam or for instant document scanning on your Mac.",
                    buttonText = if (isCameraAccessGranted) "Camera Ready" else "Enable Camera",
                    isEnabled = !isCameraAccessGranted,
                    onAction = {
                        cameraLauncher.launch(Manifest.permission.CAMERA)
                    }
                )
                10 -> PermissionStep(
                    icon = Icons.Rounded.Notifications,
                    title = "App Notifications",
                    description = "Allow the app to show you important status updates and connection alerts.",
                    buttonText = if (isPostNotificationsGranted) "Notifications On" else "Allow Notifications",
                    isEnabled = !isPostNotificationsGranted,
                    onAction = {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            postNotificationsLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
                        } else {
                            onPostNotificationsGranted()
                        }
                    }
                )
            }
        }

        // Pager Indicator
        Row(
            Modifier
                .height(48.dp)
                .fillMaxWidth(),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically
        ) {
            repeat(11) { iteration ->
                val isSelected = pagerState.currentPage == iteration
                val color = if (isSelected) 
                    MaterialTheme.colorScheme.primary 
                else 
                    MaterialTheme.colorScheme.primary.copy(alpha = 0.2f)
                
                Box(
                    modifier = Modifier
                        .padding(horizontal = 4.dp)
                        .clip(CircleShape)
                        .size(if (isSelected) 10.dp else 8.dp)
                ) {
                    Surface(color = color, modifier = Modifier.fillMaxSize()) {}
                }
            }
        }
        Spacer(modifier = Modifier.height(32.dp))
    }
}

/**
 * Displays a single permission step in the onboarding flow, including icon, title, description, and action button.
 *
 * @param icon The icon to display for this permission.
 * @param title The title of the permission step.
 * @param description A short explanation of why the permission is needed.
 * @param buttonText The text for the action button.
 * @param isEnabled Whether the action button is enabled.
 * @param onAction Callback when the action button is pressed.
 */
@Composable
fun PermissionStep(
    icon: ImageVector,
    title: String,
    description: String,
    buttonText: String,
    isEnabled: Boolean,
    onAction: (Context) -> Unit
) {
    val context = LocalContext.current
    
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Surface(
            modifier = Modifier.size(160.dp),
            shape = RoundedCornerShape(48.dp),
            color = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.3f)
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                modifier = Modifier
                    .padding(40.dp)
                    .fillMaxSize(),
                tint = MaterialTheme.colorScheme.primary
            )
        }

        Spacer(modifier = Modifier.height(48.dp))

        Text(
            text = title,
            style = MaterialTheme.typography.displayMedium,
            fontWeight = FontWeight.Black,
            textAlign = TextAlign.Center,
            lineHeight = MaterialTheme.typography.displayMedium.lineHeight,
            color = MaterialTheme.colorScheme.onBackground
        )

        Spacer(modifier = Modifier.height(16.dp))

        Text(
            text = description,
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(modifier = Modifier.height(64.dp))

        Button(
            onClick = { onAction(context) },
            enabled = isEnabled,
            modifier = Modifier
                .fillMaxWidth()
                .height(72.dp),
            shape = RoundedCornerShape(50),
            colors = ButtonDefaults.buttonColors(
                containerColor = MaterialTheme.colorScheme.primaryContainer,
                contentColor = MaterialTheme.colorScheme.onPrimaryContainer,
                disabledContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                disabledContentColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.38f)
            )
        ) {
            Text(
                text = buttonText,
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.Bold
            )
        }
    }
}

/**
 * SuccessScreen displays a confirmation UI when all permissions are granted and setup is complete.
 * Also starts DataBridgeService so data syncing begins immediately.
 */
@Composable
fun SuccessScreen() {
    val context = LocalContext.current
    // Start the data bridge service when all permissions are in place
    LaunchedEffect(Unit) {
        val serviceIntent = Intent(context, DataBridgeService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.startForegroundService(serviceIntent)
        } else {
            context.startService(serviceIntent)
        }
    }

    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(32.dp)
        ) {
            var visible by remember { mutableStateOf(false) }
            LaunchedEffect(Unit) { visible = true }

            AnimatedVisibility(
                visible = visible,
                enter = fadeIn() + scaleIn(initialScale = 0.8f, animationSpec = spring())
            ) {
                Icon(
                    imageVector = Icons.Rounded.CheckCircle,
                    contentDescription = null,
                    modifier = Modifier.size(140.dp),
                    tint = MaterialTheme.colorScheme.primary
                )
            }
            
            Spacer(modifier = Modifier.height(40.dp))
            
            Text(
                text = "Fully Connected",
                style = MaterialTheme.typography.displaySmall,
                fontWeight = FontWeight.Black,
                textAlign = TextAlign.Center
            )
            
            Spacer(modifier = Modifier.height(16.dp))
            
            Text(
                text = "Everything is set up! Your phone and Mac are now working together seamlessly.",
                style = MaterialTheme.typography.bodyLarge,
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(48.dp))

            OutlinedButton(
                onClick = {
                    val service = DataBridgeService.instance ?: return@OutlinedButton
                    val json = """{"type":"push_notification","pkg":"com.aaronmompie.phoneconnect","title":"Test Notification","text":"Hello from your Android phone! 👋","ts":${System.currentTimeMillis()}}"""
                    service.pushEvent(json)
                }
            ) {
                Text("Send Test Notification")
            }
        }
    }
}

private fun isIgnoringBatteryOptimizations(context: Context): Boolean {
    val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
    return powerManager.isIgnoringBatteryOptimizations(context.packageName)
}

private fun isNotificationListenerEnabled(context: Context): Boolean {
    val flat = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
    return flat?.contains(context.packageName) == true
}

private fun isGalleryPermissionGranted(context: Context): Boolean {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_MEDIA_IMAGES) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.READ_MEDIA_VIDEO) == PackageManager.PERMISSION_GRANTED
    } else {
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
    }
}

private fun isPhonePermissionGranted(context: Context): Boolean {
    val base = ContextCompat.checkSelfPermission(context, Manifest.permission.CALL_PHONE) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALL_LOG) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_CALL_LOG) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.READ_PHONE_STATE) == PackageManager.PERMISSION_GRANTED
    val answerPerm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        ContextCompat.checkSelfPermission(context, Manifest.permission.ANSWER_PHONE_CALLS) == PackageManager.PERMISSION_GRANTED
    } else true
    return base && answerPerm
}

private fun isSmsPermissionGranted(context: Context): Boolean {
    return ContextCompat.checkSelfPermission(context, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED
}

private fun isCameraPermissionGranted(context: Context): Boolean {
    return ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
}

private fun isMicrophonePermissionGranted(context: Context): Boolean {
    return ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
}

private fun isLocationPermissionGranted(context: Context): Boolean {
    return ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED
}

private fun isPostNotificationsPermissionGranted(context: Context): Boolean {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    } else {
        true
    }
}

private fun isNearbyDevicesPermissionGranted(context: Context): Boolean {
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
        ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED &&
                ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
    } else {
        true
    }
}

private fun isOverlayPermissionGranted(context: Context): Boolean {
    return Settings.canDrawOverlays(context)
}

private fun launchBatterySettings(context: Context) {
    val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
        data = Uri.parse("package:${context.packageName}")
    }
    context.startActivity(intent)
}

private fun launchNotificationSettings(context: Context) {
    val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
    context.startActivity(intent)
}

private fun launchOverlaySettings(context: Context) {
    val intent = Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).apply {
        data = Uri.parse("package:${context.packageName}")
    }
    context.startActivity(intent)
}
