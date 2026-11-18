import Foundation

/// Estimates a charge percentage from the battery voltage.
///
/// Feature 0x1001 reports millivolts and nothing else: functions 0x01, 0x10 and 0x20 on this device
/// all echo the same three-byte voltage reply, and the 0x1000 (battery level status) and 0x1004
/// (unified battery) features are absent. So the percentage is derived from the discharge curve the
/// Linux kernel uses for BATTERY_VOLTAGE devices (`hidpp20_map_battery_capacity`).
///
/// Caveats worth remembering, all inherited from that approach:
///  - the curve is generic; Logitech warns it doesn't fit every battery technology
///  - while charging, the cell sits above its resting voltage, so the estimate reads high
///  - it is an estimate, and the UI says "≈"
enum BatteryEstimator {

    /// Millivolts at 100 %, 99 %, … 1 %, from the kernel's `voltages[100]` table.
    private static let curve: [Int] = [
        4186, 4156, 4143, 4133, 4122, 4113, 4103, 4094, 4086, 4075,
        4067, 4059, 4051, 4043, 4035, 4027, 4019, 4011, 4003, 3997,
        3989, 3983, 3976, 3969, 3961, 3955, 3949, 3942, 3935, 3929,
        3922, 3916, 3909, 3902, 3896, 3890, 3883, 3877, 3870, 3865,
        3859, 3853, 3848, 3842, 3837, 3833, 3828, 3824, 3819, 3815,
        3811, 3808, 3804, 3800, 3797, 3793, 3790, 3787, 3784, 3781,
        3778, 3775, 3772, 3770, 3767, 3764, 3762, 3759, 3757, 3754,
        3751, 3748, 3744, 3741, 3737, 3734, 3730, 3726, 3724, 3720,
        3717, 3714, 3710, 3706, 3702, 3697, 3693, 3688, 3683, 3677,
        3671, 3666, 3662, 3658, 3654, 3646, 3633, 3612, 3579, 3537,
    ]

    /// Percentage 0…100, or nil if the voltage is outside anything a mouse battery could produce.
    static func percent(forMillivolts millivolts: Int) -> Int? {
        guard millivolts > 2500, millivolts < 5000 else { return nil }
        for (index, threshold) in curve.enumerated() where millivolts >= threshold {
            return 100 - index
        }
        return 0
    }

    /// The device's own "full" flag beats the curve: a full cell on a trickle charger sits at ~4.12 V,
    /// which the generic curve reads as ~96 %.
    static func percent(forMillivolts millivolts: Int, flags: UInt8) -> Int? {
        let charging = flags & 0x80 != 0
        if charging, flags & 0x07 == 1 { return 100 }
        return percent(forMillivolts: millivolts)
    }
}
