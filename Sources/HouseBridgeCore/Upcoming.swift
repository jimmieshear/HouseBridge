import Foundation

public struct UpcomingEvent: Identifiable, Sendable {
    /// Stable across refreshes, so the list does not rebuild its rows every minute.
    public var id: String { "\(ruleName ?? title)|\(date.timeIntervalSince1970)" }
    public var date: Date
    public var title: String
    public var detail: String
    /// Set for events that come from a rule: the window can run it right away, or skip this one occurrence.
    public var ruleName: String?
    /// This occurrence will not run (the person skipped it).
    public var skipped = false
}

/// Everything automatic that is coming up, soonest first: time-of-day rules, holiday lighting, simulated-occupancy
/// sessions and presence holds that are about to end. Pure, so the window and the tests share it.
public enum Upcoming {
    /// Identifies one occurrence of a scheduled rule, for skipping it.
    public static func skipKey(_ rule: String, _ date: Date) -> String { "\(rule)|\(Int(date.timeIntervalSince1970))" }

    /// `holds` are the saved presence hold expiry dates by name (`HoldStore.load()`).
    public static func events(config: Config, holds: [String: Date] = [:], skips: Set<String> = [], now: Date = Date(),
                              ruleHours: Double = 48, simulationDays: Int = 7, limit: Int = 40,
                              calendar: Calendar = .current) -> [UpcomingEvent] {
        var out: [UpcomingEvent] = []
        let rangeEnd = now.addingTimeInterval(ruleHours * 3600)
        let clock = DateFormatter(); clock.dateFormat = "HH:mm"

        for rule in config.rules where rule.enabled {
            guard let schedule = rule.trigger.schedule else { continue }
            var after = now
            for _ in 0..<8 {   // a daily rule shows up once per day inside the window
                guard let next = schedule.next(after: after, location: config.location, calendar: calendar), next <= rangeEnd else { break }
                out.append(UpcomingEvent(date: next, title: rule.name, detail: schedule.summary, ruleName: rule.name,
                                         skipped: skips.contains(skipKey(rule.name, next))))
                after = next
            }
        }
        for holiday in config.holidays where holiday.enabled {
            guard let window = holiday.upcoming(after: now, location: config.location, calendar: calendar).first else { continue }
            if window.start > now {
                out.append(UpcomingEvent(date: window.start, title: "Holiday lights: \(holiday.name)", detail: "until \(clock.string(from: window.end))"))
            } else {
                out.append(UpcomingEvent(date: window.end, title: "Holiday lights end: \(holiday.name)", detail: "running now"))
            }
        }
        for simulation in config.simulations where simulation.enabled {
            for session in simulation.upcoming(after: now, location: config.location, calendar: calendar, days: simulationDays) where session.start > now {
                let target = simulation.choices[session.choice].target
                let where_ = (target.rooms + target.lights + target.zones).joined(separator: ", ")
                out.append(UpcomingEvent(date: session.start, title: "Looks lived in: \(where_)",
                                         detail: "\(clock.string(from: session.start))–\(clock.string(from: session.end))"))
            }
        }
        for hold in config.presence {
            if let until = holds[hold.name], until > now {
                out.append(UpcomingEvent(date: until, title: "Presence hold ends: \(hold.name)", detail: "automation resumes"))
            }
        }
        return Array(out.sorted { $0.date < $1.date }.prefix(limit))
    }
}
