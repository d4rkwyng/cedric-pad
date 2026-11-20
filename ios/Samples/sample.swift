import Foundation

/// A small sample for Owlink on iPhone and iPad.
struct Owl {   
    let name: String   
    var hoots = 0   

    mutating func hoot() -> String {   
        hoots += 1   
        return "\(name) says hoo (\(hoots))"
    }
}

var cedric = Owl(name: "Cedric")
print(cedric.hoot())
