//
//  SAFollowButton.swift
//  ToggleButton
//
//  Created by Sean Allen on 6/21/17.
//  Copyright © 2017 Sean Allen. All rights reserved.
//

import UIKit

class ToggleButton: UIButton {
    
    var isOn = false
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        initButton()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        initButton()
    }
    
    func initButton() {
        layer.borderWidth = 2.0
        layer.borderColor = Colors.twitterBlue.cgColor
        layer.cornerRadius = frame.size.height/2
        
        setTitleColor(Colors.twitterBlue, for: .normal)
        addTarget(self, action: #selector(ToggleButton.buttonPressed), for: .touchUpInside)
    }
    
    @objc func buttonPressed() {
        if (!isOn) {
            if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                fileURL = dir.appendingPathComponent(file)
                do {
                    try FileManager.default.removeItem(at: fileURL)
                } catch let error as NSError {
                    print("Error: \(error.domain)")
                }
                print("created shio.txt")
            }
        }
        activateButton(bool: !isOn)
    }
    
    func activateButton(bool: Bool) {
        
        isOn = bool
        
        let color = bool ? Colors.twitterBlue : .clear
        let title = bool ? "Stop Record" : "Record"
        let titleColor = bool ? .white : Colors.twitterBlue
        
        setTitle(title, for: .normal)
        setTitleColor(titleColor, for: .normal)
        backgroundColor = color
    }

    
}
