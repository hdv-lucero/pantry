# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

# The Rails 8 authentication generator ships no sign-up UI, so the first account
# has to come from here. Override with SEED_EMAIL / SEED_PASSWORD.
email = ENV.fetch("SEED_EMAIL", "david@pantry.test")
password = ENV.fetch("SEED_PASSWORD", "pantrypantry")

user = User.find_or_initialize_by(email_address: email)
user.password = password
user.save!

puts "Seeded user #{user.email_address} (password: #{password})"

# A plausible household pantry, and the base state demo mode resets to (§6).
# Expiry dates are relative to today so the "use soon" section (§4.1) always has
# something in it: milk, spinach, and chicken thighs are the near-expiry three.
pantry_items = [
  # Fridge
  { name: "milk",           quantity: 1,   unit: "gallon", location: :fridge,  category: :dairy,      expires_in: 2 },
  { name: "eggs",           quantity: 8,   unit: "pcs",    location: :fridge,  category: :protein,    expires_in: 10 },
  { name: "greek yogurt",   quantity: 4,   unit: "cups",   location: :fridge,  category: :dairy,      expires_in: 6 },
  { name: "baby spinach",   quantity: 1,   unit: "bag",    location: :fridge,  category: :produce,    expires_in: 2 },
  { name: "carrots",        quantity: 6,   unit: "pcs",    location: :fridge,  category: :produce,    expires_in: 12 },
  { name: "cheddar cheese", quantity: 200, unit: "g",      location: :fridge,  category: :dairy,      expires_in: 21 },
  { name: "chicken thighs", quantity: 4,   unit: "pcs",    location: :fridge,  category: :protein,    expires_in: 1 },
  { name: "salsa",          quantity: 1,   unit: "jar",    location: :fridge,  category: :condiments, expires_in: 30 },

  # Freezer
  { name: "frozen peas",    quantity: 500, unit: "g",      location: :freezer, category: :produce,    expires_in: 180 },
  { name: "ground beef",    quantity: 1,   unit: "lb",     location: :freezer, category: :protein,    expires_in: 90 },
  { name: "salmon fillets", quantity: 2,   unit: "pcs",    location: :freezer, category: :protein,    expires_in: 60 },
  { name: "puff pastry",    quantity: 1,   unit: "sheet",  location: :freezer, category: :grains,     expires_in: 120 },

  # Pantry
  { name: "rice",           quantity: 2,   unit: "kg",     location: :pantry,  category: :grains },
  { name: "spaghetti",      quantity: 500, unit: "g",      location: :pantry,  category: :grains },
  { name: "black beans",    quantity: 3,   unit: "cans",   location: :pantry,  category: :protein },
  { name: "crushed tomatoes", quantity: 2, unit: "cans",   location: :pantry,  category: :produce },
  { name: "olive oil",      quantity: 750, unit: "ml",     location: :pantry,  category: :condiments },
  { name: "soy sauce",      quantity: 1,   unit: "bottle", location: :pantry,  category: :condiments },
  { name: "yellow onions",  quantity: 4,   unit: "pcs",    location: :pantry,  category: :produce,    expires_in: 14 },
  { name: "garlic",         quantity: 1,   unit: "bulb",   location: :pantry,  category: :produce,    expires_in: 21 },
  { name: "all-purpose flour", quantity: 1, unit: "kg",    location: :pantry,  category: :grains },
  { name: "peanut butter",  quantity: 1,   unit: "jar",    location: :pantry,  category: :condiments }
]

pantry_items.each do |attributes|
  attributes = attributes.dup
  expires_in = attributes.delete(:expires_in)
  attributes[:expires_on] = expires_in.days.from_now.to_date if expires_in

  # Names are normalized on assignment, and `normalizes` applies to finder
  # conditions too, so re-running this matches the row it created last time.
  item = PantryItem.find_or_initialize_by(name: attributes[:name], location: attributes[:location])
  item.update!(attributes)
end

puts "Seeded #{pantry_items.size} pantry items " \
     "(#{PantryItem.expiring_soon.count} expiring within #{PantryItem::EXPIRING_SOON_WINDOW.inspect})"
