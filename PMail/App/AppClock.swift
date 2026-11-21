import Foundation
import PMailKit

/// The clock the window goes by. Debug runs on the sample accounts can fix the day it thinks it is.
enum AppClock {
    nonisolated(unsafe) static var now: @Sendable () -> Date = Date.init

    static var formatting: MailFormatting { MailFormatting(now: now) }
}
