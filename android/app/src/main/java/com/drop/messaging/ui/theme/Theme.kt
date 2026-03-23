package com.drop.messaging.ui.theme

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

private val DropBlue = Color(0xFF2196F3)
private val DropBlueDark = Color(0xFF90CAF9)

private val DarkColorScheme = darkColorScheme(
    primary = DropBlueDark,
    secondary = Color(0xFF80CBC4),
    tertiary = Color(0xFFCE93D8),
    surface = Color(0xFF1A1A2E),
    background = Color(0xFF121212),
)

private val LightColorScheme = lightColorScheme(
    primary = DropBlue,
    secondary = Color(0xFF009688),
    tertiary = Color(0xFF7B1FA2),
    surface = Color(0xFFFFFBFE),
    background = Color(0xFFFFFBFE),
)

@Composable
fun DropTheme(
    darkTheme: Boolean = isSystemInDarkTheme(),
    dynamicColor: Boolean = true,
    content: @Composable () -> Unit
) {
    val colorScheme = when {
        dynamicColor && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S -> {
            val context = LocalContext.current
            if (darkTheme) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
        }
        darkTheme -> DarkColorScheme
        else -> LightColorScheme
    }

    MaterialTheme(
        colorScheme = colorScheme,
        content = content
    )
}
