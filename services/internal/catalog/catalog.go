// Package catalog holds the seeded, in-memory item data.
package catalog

// Item is a catalog entry.
type Item struct {
	ID          string  `json:"id"`
	Name        string  `json:"name"`
	Category    string  `json:"category"`
	Price       float64 `json:"price"`
	Description string  `json:"description"`
}

// Items is the static seed data. A database is out of scope for this exercise.
var Items = []Item{
	{ID: "item-1", Name: "Trail Running Shoes", Category: "footwear", Price: 129.00,
		Description: "Lightweight trail shoes with a grippy lugged outsole, rock plate and breathable mesh upper. 8mm drop, 290g per shoe."},
	{ID: "item-2", Name: "Insulated Water Bottle", Category: "accessories", Price: 34.50,
		Description: "750ml double-walled stainless steel bottle. Keeps drinks cold for 24 hours or hot for 12. Leak-proof lid, dishwasher safe."},
	{ID: "item-3", Name: "Ultralight Rain Jacket", Category: "apparel", Price: 189.00,
		Description: "Three-layer waterproof breathable shell weighing 210g. Packs into its own pocket, adjustable hood, pit zips for ventilation."},
	{ID: "item-4", Name: "Headlamp 400", Category: "accessories", Price: 49.99,
		Description: "USB-C rechargeable headlamp, 400 lumens max, red night-vision mode, IPX4 water resistance, up to 60 hours on low."},
	{ID: "item-5", Name: "Merino Base Layer", Category: "apparel", Price: 79.00,
		Description: "150gsm merino wool long-sleeve top. Naturally odour resistant, temperature regulating, flatlock seams to prevent chafing."},
}

// Find returns the item with the given ID.
func Find(id string) (Item, bool) {
	for _, it := range Items {
		if it.ID == id {
			return it, true
		}
	}
	return Item{}, false
}
