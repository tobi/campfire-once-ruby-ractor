# frozen_string_literal: true

module Campfire
  # /play sounds (upstream app/models/sound.rb).
  class Sound
    class Image < Struct.new(:asset_path, :width, :height)
      def initialize(name:, width:, height:)
        super("sounds/#{name}", width, height)
      end
    end

    def self.find_by_name(name) = INDEX[name]
    def self.names = INDEX.keys.sort

    attr_reader :name, :asset_path, :image, :text

    def initialize(name:, text: nil, image: nil)
      @name = name
      @asset_path = "#{name}.mp3"
      if image
        @image = Image.new(**image)
      else
        @text = text
      end
    end

    BUILTIN = [
      new(name: "56k", image: { name: "56k.webp", width: 79, height: 33 }),
      new(name: "bell", text: "🔔"),
      new(name: "bezos", text: "😆💭"),
      new(name: "bueller", text: "anyone?"),
      new(name: "butts", text: "👐 🚬"),
      new(name: "clowntown", image: { name: "clowntown.webp", width: 210, height: 150 }),
      new(name: "cottoneyejoe", text: "🎶🙉🎶 "),
      new(name: "crickets", text: "hears crickets chirping"),
      new(name: "curb", image: { name: "curb.webp", width: 150, height: 101 }),
      new(name: "dadgummit", text: "dad gummit!! 🎣"),
      new(name: "dangerzone", image: { name: "dangerzone.webp", width: 157, height: 32 }),
      new(name: "danielsan", text: "🎆 🏆 🎆"),
      new(name: "deeper", image: { name: "top.webp", width: 188, height: 80 }),
      new(name: "ballmer", text: "developers!"),
      new(name: "donotwant", image: { name: "donotwant.webp", width: 150, height: 150 }),
      new(name: "drama", image: { name: "drama.webp", width: 300, height: 16 }),
      new(name: "flawless", text: "#flawless"),
      new(name: "glados", text: "🤖💢"),
      new(name: "gogogo", text: "Go, go, go!"),
      new(name: "greatjob", image: { name: "greatjob.webp", width: 79, height: 16 }),
      new(name: "greyjoy", text: "😖🎺"),
      new(name: "guarantee", text: "guarantees it 👌"),
      new(name: "heygirl", text: "✨💁✨"),
      new(name: "honk", text: "HONK"),
      new(name: "horn", text: "🐶 ✂️ 🐱"),
      new(name: "horror", text: "💀 💀 💀 💀 💀 💀 💀"),
      new(name: "inconceivable", text: "doesn't think it means what you think it means…"),
      new(name: "letitgo", text: "❄️👩❄️⛄️❄️"),
      new(name: "live", text: "is DOING IT LIVE"),
      new(name: "loggins", image: { name: "loggins.webp", width: 200, height: 151 }),
      new(name: "makeitso", text: "make it so 👉"),
      new(name: "noooo", text: "👸💀😒"),
      new(name: "nyan", image: { name: "nyan.webp", width: 36, height: 15 }),
      new(name: "ohmy", text: "raises an eyebrow 😏"),
      new(name: "ohyeah", text: "isn't playing by the rules"),
      new(name: "pushit", image: { name: "pushit.webp", width: 104, height: 15 }),
      new(name: "rimshot", text: "plays a rimshot"),
      new(name: "rollout", text: "is rolling out 🚗"),
      new(name: "rumble", image: { name: "rumble.webp", width: 220, height: 150 }),
      new(name: "sax", text: "🌇🎷🎶"),
      new(name: "secret", text: "found a secret area 🔑"),
      new(name: "sexyback", text: "🔞"),
      new(name: "story", text: "and now you know…"),
      new(name: "tada", text: "plays a fanfare 🎏"),
      new(name: "tmyk", text: "✨ ⭐️ The More You Know ✨ ⭐️"),
      new(name: "totes", text: "😁👍"),
      new(name: "trololo", text: "трололо"),
      new(name: "trombone", text: "plays a sad trombone"),
      new(name: "unix", text: "knows this 💻"),
      new(name: "vuvuzela", text: "======<() ~ ♪ ~♫"),
      new(name: "what", image: { name: "what.webp", width: 100, height: 131 }),
      new(name: "whoomp", text: "👏‼️😎"),
      new(name: "wups", text: "wups!"),
      new(name: "yay", image: { name: "yay.webp", width: 103, height: 50 }),
      new(name: "yeah", image: { name: "yeah.webp", width: 104, height: 15 }),
      new(name: "yodel", text: "📣🗻🙉")
    ]

    INDEX = BUILTIN.to_h { |s| [s.name, s] }.freeze
  end
end
