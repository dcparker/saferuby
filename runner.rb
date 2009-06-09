#!/usr/bin/ruby

CustomScript = "#{ARGV[0]}"
CustomScript.untaint

s = Thread.new {
  $SAFE = 2
  load("wrapper.rb", true)
}
s.join
