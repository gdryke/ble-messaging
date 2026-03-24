package com.drop.messaging.ui.screens

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Bluetooth
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Badge
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.AlertDialog
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import com.drop.messaging.ble.BleManager
import com.drop.messaging.data.DropRepository
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConversationListScreen(
    onConversationClick: (peerId: String, peerName: String) -> Unit,
    onProfileClick: () -> Unit = {},
    onNearbyClick: () -> Unit = {}
) {
    val context = LocalContext.current
    val repository = remember(context) { DropRepository(context) }
    val conversations by repository.conversations.collectAsState(initial = emptyList())
    val nearbyPeers by BleManager.nearbyPeers.collectAsState()
    var showAddPeerDialog by remember { mutableStateOf(false) }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Drop") },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                    titleContentColor = MaterialTheme.colorScheme.onPrimaryContainer
                ),
                actions = {
                    IconButton(onClick = onNearbyClick) {
                        Icon(
                            Icons.Default.Bluetooth,
                            contentDescription = "Nearby devices",
                            tint = MaterialTheme.colorScheme.onPrimaryContainer
                        )
                    }
                    IconButton(onClick = onProfileClick) {
                        Icon(
                            Icons.Default.Person,
                            contentDescription = "Profile",
                            tint = MaterialTheme.colorScheme.onPrimaryContainer
                        )
                    }
                }
            )
        },
        floatingActionButton = {
            FloatingActionButton(
                onClick = { showAddPeerDialog = true },
                containerColor = MaterialTheme.colorScheme.primary,
                contentColor = MaterialTheme.colorScheme.onPrimary
            ) {
                Icon(Icons.Default.Add, contentDescription = "Add peer")
            }
        }
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
        ) {
            // BLE status bar
            BleStatusBar(nearbyCount = nearbyPeers.size, onTap = onNearbyClick)

            if (conversations.isEmpty()) {
                Box(
                    modifier = Modifier
                        .fillMaxSize()
                        .weight(1f),
                    contentAlignment = Alignment.Center
                ) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(
                            text = "No conversations yet",
                            style = MaterialTheme.typography.titleMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = "Tap + to add a peer, or find nearby devices via Bluetooth",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }
            } else {
                LazyColumn(modifier = Modifier.weight(1f)) {
                    items(conversations, key = { it.peerId }) { conversation ->
                        ConversationItem(
                            conversation = conversation,
                            onClick = { onConversationClick(conversation.peerId, conversation.peerName) }
                        )
                        HorizontalDivider(
                            modifier = Modifier.padding(start = 72.dp),
                            color = MaterialTheme.colorScheme.outlineVariant
                        )
                    }
                }
            }
        }
    }

    if (showAddPeerDialog) {
        AddPeerDialog(
            onDismiss = { showAddPeerDialog = false },
            onConfirm = { publicKeyHex, displayName ->
                val publicKey = publicKeyHex.hexToByteArraySafe()
                if (publicKey != null) {
                    val peerId = repository.addPeer(publicKey, displayName)
                    if (peerId.isNotEmpty()) {
                        onConversationClick(peerId, displayName)
                    }
                }
                showAddPeerDialog = false
            }
        )
    }
}

@Composable
private fun BleStatusBar(nearbyCount: Int, onTap: () -> Unit) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onTap),
        color = if (nearbyCount > 0)
            MaterialTheme.colorScheme.primaryContainer
        else
            MaterialTheme.colorScheme.surfaceVariant
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                Icons.Default.Bluetooth,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = if (nearbyCount > 0)
                    MaterialTheme.colorScheme.primary
                else
                    MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text(
                text = if (nearbyCount > 0)
                    "$nearbyCount device(s) nearby"
                else
                    "Scanning for peers\u2026",
                style = MaterialTheme.typography.labelMedium,
                color = if (nearbyCount > 0)
                    MaterialTheme.colorScheme.onPrimaryContainer
                else
                    MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun AddPeerDialog(
    onDismiss: () -> Unit,
    onConfirm: (publicKeyHex: String, displayName: String) -> Unit
) {
    var publicKey by remember { mutableStateOf("") }
    var displayName by remember { mutableStateOf("") }
    val isValid = publicKey.length == 64 &&
            publicKey.all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' } &&
            displayName.isNotBlank()

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Add Peer") },
        text = {
            Column {
                Text(
                    text = "Enter the peer's public key and a display name to start a conversation.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.height(16.dp))
                OutlinedTextField(
                    value = displayName,
                    onValueChange = { displayName = it },
                    label = { Text("Display Name") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
                Spacer(modifier = Modifier.height(12.dp))
                OutlinedTextField(
                    value = publicKey,
                    onValueChange = { publicKey = it.filter { c ->
                        c in '0'..'9' || c in 'a'..'f' || c in 'A'..'F'
                    }.take(64) },
                    label = { Text("Public Key (hex)") },
                    supportingText = { Text("${publicKey.length}/64 hex characters") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            }
        },
        confirmButton = {
            Button(
                onClick = { onConfirm(publicKey, displayName.trim()) },
                enabled = isValid
            ) {
                Text("Add")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}

private fun String.hexToByteArraySafe(): ByteArray? {
    if (length % 2 != 0) return null
    return try {
        chunked(2).map { it.toInt(16).toByte() }.toByteArray()
    } catch (e: NumberFormatException) {
        null
    }
}

@Composable
private fun ConversationItem(
    conversation: DropRepository.PeerConversation,
    onClick: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Avatar placeholder
        Surface(
            modifier = Modifier
                .size(48.dp)
                .clip(CircleShape),
            color = MaterialTheme.colorScheme.secondaryContainer
        ) {
            Box(contentAlignment = Alignment.Center) {
                Text(
                    text = conversation.peerName.take(1).uppercase(),
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSecondaryContainer
                )
            }
        }

        Spacer(modifier = Modifier.width(16.dp))

        Column(modifier = Modifier.weight(1f)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = conversation.peerName,
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = if (conversation.unreadCount > 0) FontWeight.Bold else FontWeight.Normal
                )
                Text(
                    text = formatTimestamp(conversation.lastMessageTimestamp),
                    style = MaterialTheme.typography.labelSmall,
                    color = if (conversation.unreadCount > 0)
                        MaterialTheme.colorScheme.primary
                    else
                        MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Spacer(modifier = Modifier.height(4.dp))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = conversation.lastMessage,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f)
                )
                if (conversation.unreadCount > 0) {
                    Spacer(modifier = Modifier.width(8.dp))
                    Badge(
                        containerColor = MaterialTheme.colorScheme.primary,
                        contentColor = MaterialTheme.colorScheme.onPrimary
                    ) {
                        Text(text = conversation.unreadCount.toString())
                    }
                }
            }
        }
    }
}

private fun formatTimestamp(timestamp: Long): String {
    val now = System.currentTimeMillis()
    val diff = now - timestamp

    return when {
        diff < 60_000 -> "now"
        diff < 3_600_000 -> "${diff / 60_000}m"
        diff < 86_400_000 -> "${diff / 3_600_000}h"
        else -> SimpleDateFormat("MMM d", Locale.getDefault()).format(Date(timestamp))
    }
}
