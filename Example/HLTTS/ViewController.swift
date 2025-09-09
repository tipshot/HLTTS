//
//  ViewController.swift
//  HLTTS
//
//  Created by RHL on 09/09/2025.
//  Copyright (c) 2025 RHL. All rights reserved.
//

import UIKit
import HLTTS
class ViewController: UIViewController {
    


    @IBOutlet weak var contentTextView: UITextView!
    
    @IBOutlet weak var logTextView: UITextView!
    
    @IBOutlet weak var voicePicker: UIPickerView!
    
    @IBOutlet weak var playBtn: UIButton!
    
    private var voiceTypes:[HLTTSVoiceType] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        voicePicker.delegate = self
        voicePicker.dataSource = self
        HLTTS.shared.delegate = self
        setVoiceType()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
        
    }
    private func setVoiceType(){
        voiceTypes = HLTTS.shared.availableVoiceTypes(language: .chinese)
        voicePicker.reloadAllComponents()
    }
    
    @IBAction func playBtnClick(_ sender: UIButton) {
        if contentTextView.text.isEmpty {
            print("无效数据")
            return
        }
        HLTTS.shared.speak(text: contentTextView.text)
    }
    
}

extension ViewController: UIPickerViewDelegate, UIPickerViewDataSource{
    
    func numberOfComponents(in pickerView: UIPickerView) -> Int {
        1
    }
    
    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        voiceTypes.count
    }
    
    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        let voiceType = voiceTypes[row]
        let name = HLTTS.shared.friendlyName(for: voiceType)
        return name
    }
    
    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        let voiceType = voiceTypes[row]
        HLTTS.shared.voiceType = voiceType
    }
}


extension ViewController:HLTTSDelegate {
    
    func didUpdateProgress(text: String, progress: Float) {
        let percent = Int(progress * 100)
        let log = "进度: \(percent)% - \(text)\n"
        logTextView.text.append(log)
        // 可选：滚动到最后一行
        let range = NSRange(location: logTextView.text.count - 1, length: 1)
        logTextView.scrollRangeToVisible(range)
    }
        
    func didFinish(text: String) {
        logTextView.text.append("播放成功")
        logTextView.text.append("=================\n")
    }
    
    func didFail(text: String, error: any Error) {
        logTextView.text.append("播放失败：\(error)")
        logTextView.text.append("=================\n")
    }
        
    
    func didStart(text: String) {
        print("didStart")
    }
    
    func didPause(text: String) {
        print("didPause")
    }
    
    func didContinue(text: String) {
        print("didContinue")
    }
    
    func didCancel(text: String) {
        print("didCancel")
    }
    
}
