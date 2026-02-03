<div align="center">

# firefox-minimal-compact-css

My personal Firefox theme.

![Screenshot](./screenshot.png)
Used theme: [Dark Matched](https://github.com/serverwentdown/matched)

</div>

## Features

- Compact, rounded UI with more Icons
- Shows amount of tabs on the Sidebery icon
- Doesn't show tabs when there is only one tab
- Use Sidebery Icon or set a hotkey via addon settings for `Open/Close sidebar panel` to switch between horizontal and vertical tabs
- Menu highlights matching to my KDE Plasma theme
- Bouncing indicator line while page is loading
- Move menu icon to the left
- Resizable Sidebar with minimal splitter that only shows on hover
- Use `SF Pro Display` font if installed

## Installation

1. Open Firefox and go to `about:config`
2. Set `toolkit.legacyUserProfileCustomizations.stylesheets` and `svg.context-properties.content.enabled` to `true`
3. Set `browser.compactmode.show` to `true`
4. Install [Sidebery](https://addons.mozilla.org/firefox/addon/sidebery/)
5. If you have used Sidebery before, you should use the minimal config otherwise use the full config

   **Minimal Config**
   - In Sidebery settings, enable `Add preface to the browser window's title if Sidebery sidebar is active`
   - Set the preface value to the invisible character between these markers: **`​`**
   - In the Styles editor, paste the contents of [sidebery.css](./sidebery.css)

   **Full Config**
   - In Sidebery settings, click on Help
   - Select Import addon data
   - Import the file [sidebery-data.json](./sidebery-data.json)
7. Go to `about:support` and click on `Open Directory` under `Profile Directory`
8. Clone the repository in this folder by opening a terminal and running `git clone --recursive https://github.com/D3SOX/firefox-minimal-compact-css.git chrome`
9. Restart Firefox
10. Open the menu then click on `More tools` -> `Customize toolbar...`. On the bottom left set the `Density` to `Compact`
11. Then depending on your preference put in the following items in the top bar  
    (Links are addons, you have to install and pin them first, the theme replaces the icons of these addons)
    - [Close Tab Button](https://addons.mozilla.org/firefox/addon/close-the-tab-button/)
    - [Sidebery](https://addons.mozilla.org/firefox/addon/sidebery/)
    - [Simple New Tab Button](https://addons.mozilla.org/firefox/addon/simple-new-tab-button/)
    - Back, Forward, Reload
    - [Reload Skip Cache Button](https://addons.mozilla.org/firefox/addon/reload-skip-cache-button/)
    - Downloads (right click and uncheck `Hide Button When Empty` if you want that)
    - URL Bar, Addon-specific Icons, Extensions icon
13. Enjoy!

## Optional: Smooth Scrolling

I also like to configure smooth scrolling similar to Zen.
To do that, go to `about:config` and set

- `general.smoothScroll.msdPhysics.continousMotionMaxDeltaMS` to `12`
- `general.smoothScroll.msdPhysics.enabled` to `true`
- `general.smoothScroll.msdPhysics.motionBeginSpringConstant` to `600`
- `general.smoothScroll.msdPhysics.regularSpringConstant` to `650`
- `general.smoothScroll.msdPhysics.slowdownMinDeltaMS` to `25`
- `general.smoothScroll.msdPhysics.slowdownSpringConstant` to `250`

## Credits

- Partially based on [ArcWTF](https://github.com/KiKaraage/ArcWTF)
- Uses CSS from [firefox-csshacks](https://github.com/MrOtherGuy/firefox-csshacks) and [CustomCSSForFx](https://github.com/Aris-t2/CustomCSSForFx)
