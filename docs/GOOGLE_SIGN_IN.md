# Google sign-in

DropDrawer opens the system browser for Google authorization and signs in automatically once authorization completes. Use the same server address and Google account on each device to open the same drawer. Google sign-in creates its own DropDrawer account on first use. Existing username and password accounts retain their own drawers.

## Google Cloud configuration

1. In [Google Auth Platform](https://console.cloud.google.com/auth/overview), configure the app name, support email and audience. Request only the `openid` and `email` scopes for sign-in. If the app is in testing, add the Google accounts allowed to sign in.
2. Create an OAuth client of type **Web application**. Add the exact public redirect URI under **Authorized redirect URIs**, for example `https://drop.example.com/api/auth/google/callback`. The server must be accessible to the system browser. Use HTTPS for a public server. Google also accepts localhost HTTP for local testing.
3. For public sign-in, set the app privacy policy URL to your server’s `/privacy` page under **Branding**. Add your domain under **Authorized domains**.
4. Set all three Google variables in the server's private `.env`. Use [.env.example](../.env.example) as the template. Use the OAuth client ID, its client secret, and the exact authorized redirect URI.
5. Restart the server and select **使用 Google 登录** on the updated DropDrawer login screen. Complete the Google prompt in the browser, then return to the app.

The Google Drive storage setup has its own OAuth client and callback. Existing Google users can still sign in when `DROPDRAWER_ALLOW_REGISTRATION=false`. First-time Google sign-ins follow the same registration policy as password accounts.

## Server environment file

- A binary started from the repository root reads `.env`. Use `DROPDRAWER_ENV_FILE` to read another path. Process environment values override file values.
- With the standard Compose file, run `docker compose --env-file .env -f deploy/docker-compose.yml up -d --build`.
- The BaoTa Compose file reads `/srv/dropdrawer/shared/.env`. Edit that file before recreating the server container. Keep its existing JWT secret and database volume to preserve sessions and files.
- Keep `.env` private and out of version control. Commit changes to `.env.example` only.

[Google's OpenID Connect guide](https://developers.google.com/identity/openid-connect/openid-connect)
