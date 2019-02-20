# ByWater RT Bugs Updater

This script updates our RT "Bugs" queue community status field from the Koha community bug it is associated with.

## How to install and configure

* Clone the repository: `git clone https://github.com/bywatersolutions/rt-bugs-updater.git`
* Symlink the shell script to some place in your executable path: `ln -s /path/to/rt-bugs-updater/bin/rt-bugs-updater /usr/local/bin/.`
* Copy the example env file to your home directory: `cp .rt-bugs-updater.env.example ~/.rt-bugs-updater.env`
* Edit that file, change the example values to your values: `vi ~/.rt-bugs-updater.env`
* Try running the command `rt-bugs-updater --help` to see how to use the app
