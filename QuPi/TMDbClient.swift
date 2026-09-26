import Foundation

/// Minimal The Movie Database (TMDb) v3 client.
/// The user supplies their own API key in Settings → Accounts.
struct TMDbClient {
    let apiKey: String

    private static let baseURL = URL(string: "https://api.themoviedb.org/3")!
    private static let imageBase = "https://image.tmdb.org/t/p/w500"

    // MARK: - Search

    struct MovieResult {
        let tmdbID: Int
        let title: String
        let year: Int?
        let posterPath: String?
    }

    struct TVResult {
        let tmdbID: Int
        let title: String
        let posterPath: String?
    }

    func searchMovie(title: String, year: Int? = nil) async -> MovieResult? {
        var query: [URLQueryItem] = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "api_key", value: apiKey),
        ]
        if let year { query.append(URLQueryItem(name: "year", value: "\(year)")) }
        guard let data = try? await get(path: "/search/movie", query: query) else { return nil }

        struct Response: Decodable {
            struct Movie: Decodable {
                let id: Int
                let title: String
                let releaseDate: String?
                let posterPath: String?
                enum CodingKeys: String, CodingKey {
                    case id, title
                    case releaseDate = "release_date"
                    case posterPath = "poster_path"
                }
            }
            let results: [Movie]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let first = response.results.first else { return nil }
        let releaseYear = first.releaseDate.flatMap { Int($0.prefix(4)) }
        return MovieResult(tmdbID: first.id, title: first.title, year: releaseYear, posterPath: first.posterPath)
    }

    func searchTV(title: String) async -> TVResult? {
        let query: [URLQueryItem] = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "api_key", value: apiKey),
        ]
        guard let data = try? await get(path: "/search/tv", query: query) else { return nil }

        struct Response: Decodable {
            struct Show: Decodable {
                let id: Int
                let name: String
                let posterPath: String?
                enum CodingKeys: String, CodingKey {
                    case id, name
                    case posterPath = "poster_path"
                }
            }
            let results: [Show]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              let first = response.results.first else { return nil }
        return TVResult(tmdbID: first.id, title: first.name, posterPath: first.posterPath)
    }

    // MARK: - Detail (by TMDb ID)

    func moviePosterPath(tmdbID: Int) async -> String? {
        struct Movie: Decodable {
            let posterPath: String?
            enum CodingKeys: String, CodingKey { case posterPath = "poster_path" }
        }
        let query = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let data = try? await get(path: "/movie/\(tmdbID)", query: query),
              let movie = try? JSONDecoder().decode(Movie.self, from: data) else { return nil }
        return movie.posterPath
    }

    func tvPosterPath(tmdbID: Int) async -> String? {
        struct Show: Decodable {
            let posterPath: String?
            enum CodingKeys: String, CodingKey { case posterPath = "poster_path" }
        }
        let query = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let data = try? await get(path: "/tv/\(tmdbID)", query: query),
              let show = try? JSONDecoder().decode(Show.self, from: data) else { return nil }
        return show.posterPath
    }

    func episodeStillPath(tvTMDbID: Int, season: Int, episode: Int) async -> String? {
        struct Episode: Decodable {
            let stillPath: String?
            enum CodingKeys: String, CodingKey { case stillPath = "still_path" }
        }
        let query = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let data = try? await get(path: "/tv/\(tvTMDbID)/season/\(season)/episode/\(episode)", query: query),
              let ep = try? JSONDecoder().decode(Episode.self, from: data) else { return nil }
        return ep.stillPath
    }

    // MARK: - URL builder

    static func posterURL(path: String) -> URL? {
        URL(string: "\(imageBase)\(path)")
    }

    // MARK: - Network

    // MARK: - Key check

    enum KeyCheck {
        case valid, invalid, unreachable
    }

    /// Asks TMDb whether the API key is accepted, distinguishing a rejected
    /// key from a network problem.
    func checkKey() async -> KeyCheck {
        var components = URLComponents(url: Self.baseURL.appending(path: "/configuration"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        guard let (_, response) = try? await URLSession.shared.data(from: components.url!),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unreachable }
        switch status {
        case 200: return .valid
        case 400..<500: return .invalid
        default: return .unreachable
        }
    }

    private func get(path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}
