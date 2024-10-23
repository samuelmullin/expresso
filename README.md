# Expresso

## Disclaimer

Implementing this project requires working with mains level electricity.  If you are not comfortable with this or if you cannot take the required precautions, please do not attempt this project.  Instructions and software contained herein should be used at your own risk and are provided without warranty or guarantee of any kind.

## What is this?

This repo houses a nerves based firmware that will add PID control to your Gaggia Classic Pro (GCP) espresso machine.  The controller is observable and configurable via a web based interface.  A circuit diagram is not currently included but will be added eventually.

## But why?

The simple answer is:  Reducing the number of variables that go into brewing espresso greatly increases the consistency of the produced espresso.  By making the temperature control much more accurate, we eliminate the temperature as a variable and we can focus on other areas to improve the quality of our shots.

The GCP is a fine entry level espresso machine, but the temperature control has a very wide range of possible temperatures.  The brew thermostat is an L107-8C, which means that when the temperature of the boiler drops below 99°C, the heater is enabled and continues to run until the boiler reaches 115°C.  Since it takes some time for the coils to shed heat after the thermostat disengages, the effective range is close to 99°C-128°C.

The generally accepted ideal temperature range to brew espresso is a much smaller - 92°C - 96°C*, so a lot of the time the built in thermostat is causing us to brew outside that range.

For reference, the steam thermostat is similar - it's an L145-15C, which engages at 130°C and disengages at 160°C.  While higher is better for steaming, the GCP has a thermal fuse at 184°C so when setting a steam temp we need to make sure that any overshoot will keep us well below that temperature.

\*If you are wondering why this range is lower than the min range of the thermostat, please read: [On boiler-to-brew-head drop](#on-boiler-to-brew-head-drop)

## On boiler-to-brew-head drop

While we control the thermostat based on the boiler temperature, there is a small but relatively consistent temperature drop between the boiler and the brew head.  Since every machine is a little bit different, you should measure this drop and set your target temperature appropriately.  Typically the drop is somewhere around 10°C.

This means that for the default thermostat, our range at the brew head is between 89°C and 118°C.
