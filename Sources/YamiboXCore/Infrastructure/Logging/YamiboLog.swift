import os

public enum YamiboLog {
    private static let subsystem = "com.arkalin.YamiboX"

    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let offlineCache = Logger(subsystem: subsystem, category: "offline-cache")
    public static let download = Logger(subsystem: subsystem, category: "downloads")
    public static let sync = Logger(subsystem: subsystem, category: "sync")
    public static let account = Logger(subsystem: subsystem, category: "account")
    public static let library = Logger(subsystem: subsystem, category: "library")
    public static let forum = Logger(subsystem: subsystem, category: "forum")
    public static let reader = Logger(subsystem: subsystem, category: "reader")
    public static let networking = Logger(subsystem: subsystem, category: "networking")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
