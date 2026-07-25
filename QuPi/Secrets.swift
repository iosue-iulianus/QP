// Fill in your credentials before building. This file is gitignored.
//
// Trakt:  Register at https://trakt.tv/oauth/applications/new
//         Set redirect URI to: qupi://trakt-auth
//
// Last.fm: Register at https://www.last.fm/api/account/create
//          Set callback URL to: qupi://lastfm-auth

enum TraktSecrets {
    static let clientID     = "577w6KIfz3-sgnZP3ypsWr8FPyblEeZWwPAOyn0OdrM"
    static let clientSecret = "2AfAG8WInvieDQOT2WcqFc_NNybFU7s8xx1yu9Zzw6g"
    static let redirectURI  = "qupi://trakt-auth"
}

enum LastFMSecrets {
    static let apiKey       = "YOUR_LASTFM_API_KEY"
    static let sharedSecret = "YOUR_LASTFM_SHARED_SECRET"
    static let callbackURL  = "qupi://lastfm-auth"
}
