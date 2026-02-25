# Notes from a human

Yes, this project has been AI agent generated. I agree that:
* the language is clumsy
* the script names are often weird
* there is a stunning lack of cohesion/orchestration (ie: no `Makefile` or other easy and common "way in")
* parts are definately "doing it the hard way"

However, it does actually work, and given the awful holes in most Radxa documentation, a working result is better than a perfectly well written projevct that fails to do anythign useful.

*Use with caution*

Parts are great - the APK build creation and the ability to insert those assets into the main image build without having to host a server as direct file paths can be used is really nice: it's a very positive way of encouraging packaging of everything over modification of the base image, which ought to make moving versions much simpler.

I am not convinced that moving versions will be that trivial, and I question the weird mix of in-script defined package installs vs the external file approach, but it is at least mostly commented/described so that the intent is not opaque.

The u-boot stuff is a real mess: I know I have written far better u-boot genericisers but I can't remember what I did, so this will have to suffice for now.
