# HLTTS

[![CI Status](https://img.shields.io/travis/RHL/HLTTS.svg?style=flat)](https://travis-ci.org/RHL/HLTTS)
[![Version](https://img.shields.io/cocoapods/v/HLTTS.svg?style=flat)](https://cocoapods.org/pods/HLTTS)
[![License](https://img.shields.io/cocoapods/l/HLTTS.svg?style=flat)](https://cocoapods.org/pods/HLTTS)
[![Platform](https://img.shields.io/cocoapods/p/HLTTS.svg?style=flat)](https://cocoapods.org/pods/HLTTS)

## Example

 iOS本地通过文本合成语音。
 支持调整 语速、音调、音量、语言，支持系统内值的所有语音类型
 支持获取当前本地的语音类型。
 内置可映射语音名称（防止样本不全，建议根据自己的实际情况自定义映射）
 可代理获取播放进度、播放成功、失败、暂停、继续、取消、开始。
 可回调获取播放完成或失败。
 支持加入队列
 支持打断
 
 

// 播放语音
let msg = "愿中国青年都摆脱冷气，只是向上走，不必听自暴自弃者流的话。能做事的做事，能发声的发声。有一分热，发一分光，就令萤火一般，也可以在黑暗里发一点光，不必等候炬火。此后如竟没有炬火：我便是唯一的光。"
 HLTTS.shared.speak(text: msg )

// 获取支持的语音
let voiceTypes = HLTTS.shared.availableVoiceTypes(language: .chinese)

## Requirements

## Installation

HLTTS is available through [CocoaPods](https://cocoapods.org). To install
it, simply add the following line to your Podfile:

```ruby
pod 'HLTTS'
```

## Author

RHL, renhanlinwy@163.com

## License

HLTTS is available under the MIT license. See the LICENSE file for more info.
