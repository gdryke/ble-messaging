package com.drop.messaging.ui.navigation

import androidx.compose.runtime.Composable
import androidx.navigation.NavType
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.navArgument
import com.drop.messaging.ui.screens.ChatScreen
import com.drop.messaging.ui.screens.ConversationListScreen

object Routes {
    const val CONVERSATIONS = "conversations"
    const val CHAT = "chat/{peerId}/{peerName}"

    fun chat(peerId: String, peerName: String): String =
        "chat/$peerId/$peerName"
}

@Composable
fun DropNavGraph() {
    val navController = rememberNavController()

    NavHost(
        navController = navController,
        startDestination = Routes.CONVERSATIONS
    ) {
        composable(Routes.CONVERSATIONS) {
            ConversationListScreen(
                onConversationClick = { peerId, peerName ->
                    navController.navigate(Routes.chat(peerId, peerName))
                }
            )
        }

        composable(
            route = Routes.CHAT,
            arguments = listOf(
                navArgument("peerId") { type = NavType.StringType },
                navArgument("peerName") { type = NavType.StringType }
            )
        ) { backStackEntry ->
            val peerId = backStackEntry.arguments?.getString("peerId") ?: return@composable
            val peerName = backStackEntry.arguments?.getString("peerName") ?: return@composable
            ChatScreen(
                peerId = peerId,
                peerName = peerName,
                onBack = { navController.popBackStack() }
            )
        }
    }
}
