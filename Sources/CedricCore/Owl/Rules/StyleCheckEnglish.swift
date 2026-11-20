import Foundation

/// Style Check's English list: filler words (cut them), redundancies (the
/// short form) and clichés (rephrase). Sources: iA Writer's and Ulysses'
/// style checks, Strunk & White's "omit needless words", the Plain
/// English Campaign's lists. Words that are often meaningful ("only",
/// "pretty" as in pretty dress) are left out. Add a language the same way:
/// a `StyleList` with its code, in `StyleCheck.lists`.
extension StyleCheck {
    public static let english = StyleList(language: "en", entries:
        ["very", "really", "just", "actually", "basically", "literally", "totally", "quite", "rather", "somewhat", "simply", "definitely",
            "certainly", "extremely", "absolutely", "completely", "honestly", "obviously", "clearly", "essentially", "practically",
            "virtually", "fairly", "kind of", "sort of", "a bit", "pretty much", "more or less", "needless to say",
            "it goes without saying", "in my opinion", "i think that", "i believe that", "as a matter of fact",
            "for all intents and purposes"].map { Entry($0, .filler, replacement: "") }
        + [("past history", "history"), ("end result", "result"), ("final outcome", "outcome"), ("free gift", "gift"), ("added bonus",
            "bonus"), ("advance planning", "planning"), ("advance warning", "warning"), ("basic fundamentals", "fundamentals"),
            ("close proximity", "proximity"), ("completely finished", "finished"), ("each and every", "each"), ("exact same", "same"),
            ("future plans", "plans"), ("joint collaboration", "collaboration"), ("new innovation", "innovation"), ("past experience",
            "experience"), ("repeat again", "repeat"), ("revert back", "revert"), ("return back", "return"), ("unexpected surprise",
            "surprise"), ("true fact", "fact"), ("atm machine", "ATM"), ("pin number", "PIN"), ("sum total", "total"), ("first began",
            "began"), ("still remains", "remains"), ("absolutely essential", "essential"), ("in order to", "to"), ("due to the fact that",
            "because"), ("at this point in time", "now"), ("in the event that", "if"), ("plan ahead", "plan"), ("merge together", "merge"),
            ("combine together", "combine"), ("collaborate together", "collaborate"), ("brief summary", "summary"), ("general consensus",
            "consensus"), ("consensus of opinion", "consensus"), ("personal opinion", "opinion"), ("over exaggerate", "exaggerate"),
            ("postpone until later", "postpone"), ("reason why", "reason"), ("still persists", "persists"), ("whether or not", "whether"),
            ("armed gunman", "gunman"), ("foreign imports", "imports"), ("mutual cooperation", "cooperation"), ("protest against",
            "protest"), ("unintended mistake", "mistake"), ("estimated at about", "estimated at"), ("descend down", "descend"),
            ("ascend up", "ascend"), ("raise up", "raise"), ("refer back", "refer"), ("sudden impulse", "impulse"), ("totally unique",
            "unique"), ("very unique", "unique"), ("12 midnight", "midnight"), ("12 noon", "noon")].map { Entry($0.0, .redundancy,
            replacement: $0.1) }
        + ["at the end of the day", "think outside the box", "low-hanging fruit", "low hanging fruit", "move the needle", "game changer",
            "game-changer", "paradigm shift", "touch base", "circle back", "best of both worlds", "few and far between",
            "in the nick of time", "only time will tell", "calm before the storm", "level playing field", "avoid it like the plague",
            "last but not least", "par for the course", "tip of the iceberg", "when all is said and done", "easier said than done",
            "cutting edge", "cutting-edge", "state of the art", "state-of-the-art", "going forward", "hit the ground running", "win-win",
            "deep dive", "push the envelope", "lion's share", "in this day and age", "all walks of life", "fit as a fiddle",
            "busy as a bee", "crystal clear", "dead as a doornail", "read between the lines", "the bottom line", "think big",
            "perfect storm", "on the same page", "take it to the next level", "a whole new ball game", "back to square one",
            "ballpark figure", "bite the bullet", "by and large", "beyond the pale", "elephant in the room", "the writing on the wall",
            "needle in a haystack", "new normal", "outside the box", "rocket science", "tried and true", "tried and tested",
            "at the drop of a hat", "every cloud has a silver lining", "sleep on it", "so to speak"].map { Entry($0, .cliche) })
}
