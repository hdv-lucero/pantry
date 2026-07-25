require "test_helper"

# The +/− stepper and the Remove button are labelled for screen readers rather
# than with visible text, so let Capybara find them the same way a screen reader
# user would.
Capybara.enable_aria_label = true

# Turbo round trips (and the stepper's 400ms debounce) need a little more slack
# than the 2s default, especially on CI.
Capybara.default_max_wait_time = 5

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  # Debian ships chromium and a version-matched chromedriver; Selenium Manager
  # would otherwise try to download a driver for a Google Chrome that isn't
  # installed, over a network the container doesn't need. CI's runner has real
  # Chrome, sets neither variable, and gets the stock behaviour.
  Selenium::WebDriver::Chrome::Service.driver_path = ENV["CHROMEDRIVER_PATH"] if ENV["CHROMEDRIVER_PATH"]

  driven_by :selenium, using: :headless_chrome, screen_size: [ 1400, 1000 ] do |options|
    options.binary = ENV["CHROME_BINARY"] if ENV["CHROME_BINARY"]
    options.add_argument("--no-sandbox")
    options.add_argument("--disable-dev-shm-usage")
  end

  private
    def sign_in_as(user, password: "password")
      visit new_session_path
      fill_in "email_address", with: user.email_address
      fill_in "password", with: password
      click_button "Sign in"

      assert_selector "h1", text: "Pantry"
    end

    # The stepper answers asynchronously, so "did it actually persist?" has to
    # wait the way Capybara's own matchers do rather than reading the row once.
    def assert_stored_quantity(pantry_item, expected)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Capybara.default_max_wait_time

      until pantry_item.reload.quantity == expected
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          flunk "expected #{pantry_item.name} to be stored with quantity #{expected}, got #{pantry_item.quantity}"
        end
        sleep 0.05
      end

      assert_equal expected, pantry_item.quantity
    end
end
