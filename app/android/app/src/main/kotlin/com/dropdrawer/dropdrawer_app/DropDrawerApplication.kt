package com.dropdrawer.dropdrawer_app

import android.app.Application
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.util.Log
import androidx.annotation.Keep

@Keep
class DropDrawerApplication : Application() {
    private external fun initializeP2pDns(): Boolean
    private external fun notifyP2pNetworkChange()

    override fun onCreate() {
        super.onCreate()
        try {
            System.loadLibrary("dropdrawer_p2p")
            if (!initializeP2pDns()) {
                Log.w("DropDrawer", "System DNS unavailable for P2P")
            }
        } catch (e: UnsatisfiedLinkError) {
            // Builds without a native library for this ABI can still use cloud storage.
            Log.w("DropDrawer", "Native P2P unavailable", e)
            return
        }

        // Keep observing the default network across Activity recreation and resume.
        getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(
            object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) = notifyP2pNetworkChange()
                override fun onLost(network: Network) = notifyP2pNetworkChange()
                override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) =
                    notifyP2pNetworkChange()
            }
        )
    }
}
