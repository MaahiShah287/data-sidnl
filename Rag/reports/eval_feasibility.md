# Eval feasibility against the real data

Generated from the live read-only views. Checks actual
(platform, city, brand) pairs, not each dimension in isolation.

## Real data

- **v_latest_observation** (price, discount, stock, ETA): **Blinkit only**, **brand = Mr. Munchies only**, 11 cities.
- **v_latest_shelf_position** (position, ads): Blinkit (Amul, Mr. Munchies, Mother Dairy) + Zepto (Amul, **Mumbai only**, 344 rows).
- No Instamart, no JioMart anywhere. Categories: Instant & Frozen Food, Sweet Tooth.

## Answerable: 2 of 25

| ID | Question | Source | Note | GT value |
|---|---|---|---|---|
| N10 | Blinkit mein kaunsi category mein sabse zyada ads hain Bangalore mein? | shelf_position |  | 3.3 |
| N18 | Which L1 categories have the highest OOS rate on Blinkit in Mumbai? | observation |  | 100.0 |

## Answerable only in a degraded form: 2 of 25

| ID | Question | Source | Note | GT value |
|---|---|---|---|---|
| N04 | Show me the top 10 brands by average organic position on Blinkit shelf in Delhi | shelf_position | asks top 10 brands, data has 2 | 131.03 |
| N25 | Which cities on Blinkit have the most distinct brands available? | shelf_position | brand cardinality is only 3 (['amul', 'mother dairy', 'mr. munchies']) | 1 |

## Not answerable from the data: 21 of 25

| ID | Question | Source | Note | GT value |
|---|---|---|---|---|
| N01 | What is the current sale price of Amul Butter 500g on Blinkit in Mumbai? | observation | brand 'amul' absent in observation | None |
| N02 | Zepto par Mumbai mein Haldiram namkeen ka average discount kya hai? | observation | platform 'zepto' has no observation rows; brand 'haldiram' absent in observation | 3.85 |
| N03 | What is the in-stock rate for Mamaearth products on Instamart in Bangalore? | observation | platform 'instamart' has no observation rows; brand 'mamaearth' absent in observation | None |
| N05 | What percentage of Zepto listings in Hyderabad are ads? | shelf_position | no shelf_position rows for ['zepto'] x ['hyderabad'] | 0.0 |
| N06 | Blinkit aur Zepto dono par Nestle products ki average sale price batao Delhi mein | observation | platform 'zepto' has no observation rows; brand 'nestle' absent in observation | None |
| N07 | Which Instamart stores in Chennai have P&G products out of stock? | observation | platform 'instamart' has no observation rows; brand 'p&g' absent in observation | 489 |
| N08 | What is the average delivery ETA on Zepto in Pune? | observation | platform 'zepto' has no observation rows | None |
| N09 | Show me Cadbury products on JioMart in Kolkata with mrp above 100 | observation | platform 'jiomart' has no observation rows; brand 'cadbury' absent in observation | None |
| N11 | What is the discount percentage range for ITC products on Blinkit across all cities? | observation | brand 'itc' absent in observation | None |
| N12 | How many Dettol SKUs are listed on Instamart in Mumbai? | shelf_position | platform 'instamart' has no shelf_position rows; brand 'dettol' absent in shelf_position | 8 |
| N13 | JioMart par Kissan products ka MRP vs sale price difference kya hai Delhi mein? | observation | platform 'jiomart' has no observation rows; brand 'kissan' absent in observation | None |
| N14 | What is the average position of Dabur products on Zepto shelf in Ahmedabad? | shelf_position | brand 'dabur' absent in shelf_position | 86.6 |
| N15 | Show availability of Britannia products on Blinkit in Jaipur | observation | city 'jaipur' absent in observation; brand 'britannia' absent in observation | None |
| N16 | How many unique brands are on Zepto platform in Chennai? | shelf_position | no shelf_position rows for ['zepto'] x ['chennai'] | 1 |
| N17 | Instamart Pune mein kaunse products ka discount 30% se zyada hai? | observation | platform 'instamart' has no observation rows | None |
| N19 | What is the price of Ghadi detergent on Blinkit vs Zepto in Delhi? | observation | platform 'zepto' has no observation rows; brand 'ghadi' absent in observation | None |
| N20 | Zepto Bangalore shelf mein top 5 brands kaun kaun se hain position ke hisab se? | shelf_position | no shelf_position rows for ['zepto'] x ['bengaluru'] | 86.6 |
| N21 | How many listings on Instamart have sale_price greater than mrp? | observation | platform 'instamart' has no observation rows | 209.0 |
| N22 | What is JioMart's average discount in the Snacks and Beverages category across all cities? | observation | platform 'jiomart' has no observation rows | None |
| N23 | Blinkit Delhi mein kitne stores pe Surf Excel available hai? | observation | brand 'surf excel' absent in observation | None |
| N24 | Show me organic vs ad positions for HUL products on Zepto in Mumbai | shelf_position | brand 'hul' absent in shelf_position | 86.6 |

