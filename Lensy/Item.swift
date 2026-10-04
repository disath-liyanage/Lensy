//
//  Item.swift
//  Lensy
//
//  Created by Disath Liyanage on 2026-10-04.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
