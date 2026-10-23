# Cross-browser adapters and portable helpers

Browser Bridge uses family-level profile readers and a neutral portable snapshot. Public Chromium/Firefox extension APIs provide live capture/import. Safari uses readable profile files or bookmark HTML and manual import.

Generic APIs do not establish native spaces/Favorites or encrypted-session equivalence. The support matrix must expose that boundary. Local native sessions take precedence over an attached capture when both contain tabs; guessing URL matches risks losing intentional duplicates and organization. The original capture stays in the package.

Only selected profiles and known external metadata are backed up. Portable-file-only mode is explicit and never claims a full source backup. Public source releases exclude all user profile/capture/journal data. MIT licensing and source availability do not imply all browser versions have been acceptance-tested.
