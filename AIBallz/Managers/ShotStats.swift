import SwiftData

@Model
final class ShotStats {
    var totalShots: Int
    var shotsMade: Int
    
    init(totalShots: Int, shotsMade: Int) {
        self.totalShots = totalShots
        self.shotsMade = shotsMade
    }
}
