// Invented content for `hippo sample` (sample.ts). Every title, note, transcript, name, channel and neighbourhood here is made up.
// Sites are real, well-known hosts so that site filters behave as on real captures; the paths and ids built from them are invented.
// Coordinates are public places in Lisbon (squares, gardens, viewpoints), never a home.

export const ZONE = 'Europe/Lisbon';
export const LOCALITY = 'Lisboa';

/** Six invented first names. */
export const NAMES = ['Marta', 'Tomás', 'Inês', 'Rui', 'Lena', 'Hugo'];

export const TOPICS = ['food', 'travel', 'music', 'home', 'work', 'reading', 'fitness', 'shopping', 'garden', 'city'] as const;
export type Topic = typeof TOPICS[number];

/** Five clusters around public places; the neighbourhood and point-of-interest names are invented. `weight`: how often captures fall there. */
export const PLACES = [
  { lat: 38.7076, lon: -9.1365, sub_locality: 'Ribeira dos Barcos', nearby: 'Harbour Steps', weight: 3 },      // a riverside square
  { lat: 38.7154, lon: -9.1445, sub_locality: 'Alto das Lanternas', nearby: 'Lantern Viewpoint', weight: 2 },   // a viewpoint
  { lat: 38.7139, lon: -9.1597, sub_locality: 'Campo das Tílias', nearby: 'Linden Garden', weight: 4 },         // a public garden
  { lat: 38.7286, lon: -9.1527, sub_locality: 'Encosta Verde', nearby: 'Long Lawn Park', weight: 2 },           // a large park
  { lat: 38.6963, lon: -9.2063, sub_locality: 'Margem do Farol', nearby: 'Lighthouse Gardens', weight: 1 },     // riverside gardens
];

/** Words left out when keywords are taken from a note or transcript. */
export const STOPWORDS = new Set(('a about after again all also an and any are as at be because been before being but by can could do '
  + 'does down each for from get go going good has have here how i if in into is it its just last let like maybe me more most my need '
  + 'next no not now of off on one only or other our out over so some still than that the their them then there these they this those '
  + 'through to too try up us very was way we were what when where which while who will with would you your then two three every '
  + 'ask back bit make sure start end day today tomorrow week minutes later').split(/\s+/));

// ---- links ----

export interface VideoItem { title: string; channel: string; topic: Topic; tags: string[]; description: string }

export const YOUTUBE_VIDEOS: VideoItem[] = [
  { title: 'Ten-minute tomato soup', channel: 'Slow Pan Kitchen', topic: 'food', tags: ['soup', 'tomato', 'recipe', 'quick'], description: 'A fast weeknight soup from tinned tomatoes, garlic and basil.' },
  { title: 'How glazed tiles are painted by hand', channel: 'Workshop Hours', topic: 'city', tags: ['tiles', 'craft', 'painting'], description: 'A painter shows each step of a blue and white tile panel.' },
  { title: 'Morning stretch for desk workers', channel: 'Quiet Body', topic: 'fitness', tags: ['stretching', 'posture', 'morning'], description: 'Twelve minutes of gentle stretches for neck, back and hips.' },
  { title: 'Fingerstyle guitar: a simple lullaby', channel: 'String Room', topic: 'music', tags: ['guitar', 'lesson', 'fingerstyle'], description: 'A slow lesson on a four-bar lullaby for beginners.' },
  { title: 'Pruning a lemon tree in autumn', channel: 'Balcony Grower', topic: 'garden', tags: ['lemon tree', 'pruning', 'autumn'], description: 'Where to cut, what to leave, and how to feed it afterwards.' },
  { title: 'Night tram ride through the old town', channel: 'Rail Window', topic: 'city', tags: ['tram', 'night', 'old town'], description: 'Twenty quiet minutes from the front window of a night tram.' },
  { title: 'Packing light for a week away', channel: 'Carry-On Notes', topic: 'travel', tags: ['packing', 'luggage', 'travel tips'], description: 'One small bag, seven days, and a list that works.' },
  { title: 'Sourdough starter, day one', channel: 'Slow Pan Kitchen', topic: 'food', tags: ['sourdough', 'bread', 'baking'], description: 'Flour, water and patience: the first day of a new starter.' },
  { title: 'Three chords, ten songs', channel: 'String Room', topic: 'music', tags: ['guitar', 'chords', 'songs'], description: 'Ten sing-along songs that use only three chords.' },
  { title: 'Fix a dripping tap in five minutes', channel: 'Weekend Fixes', topic: 'home', tags: ['repair', 'plumbing', 'tap'], description: 'Replace the washer and stop the drip without calling anyone.' },
  { title: 'Speed reading myths, tested', channel: 'Page Lab', topic: 'reading', tags: ['reading', 'speed reading', 'study'], description: 'Three popular tricks measured against plain careful reading.' },
  { title: 'Interval run for beginners', channel: 'Quiet Body', topic: 'fitness', tags: ['running', 'intervals', 'beginners'], description: 'A twenty-minute run-walk session with a timer on screen.' },
  { title: 'Writing better meeting notes', channel: 'Desk Habits', topic: 'work', tags: ['meetings', 'notes', 'productivity'], description: 'A one-page template for notes people actually read.' },
  { title: 'Repotting succulents without the mess', channel: 'Balcony Grower', topic: 'garden', tags: ['succulents', 'repotting', 'plants'], description: 'Soil mix, pot size and how to handle the spiky ones.' },
  { title: 'Best viewpoints by the river', channel: 'Carry-On Notes', topic: 'travel', tags: ['viewpoints', 'river', 'walks'], description: 'Five places to watch the sunset, from busy to almost empty.' },
  { title: 'Building a standing desk from scrap wood', channel: 'Weekend Fixes', topic: 'home', tags: ['desk', 'woodwork', 'diy'], description: 'Two old shelves, a saw and an afternoon.' },
];

export const YOUTUBE_SHORTS: VideoItem[] = [
  { title: 'Garlic peeling trick', channel: 'Slow Pan Kitchen', topic: 'food', tags: ['garlic', 'kitchen tips', 'cooking'], description: 'Two bowls and ten seconds of shaking.' },
  { title: 'One-minute plank check', channel: 'Quiet Body', topic: 'fitness', tags: ['plank', 'core', 'form'], description: 'Three things to check in your plank.' },
  { title: 'Folding a fitted sheet', channel: 'Weekend Fixes', topic: 'home', tags: ['laundry', 'folding', 'home tips'], description: 'Corners into corners, then fold in thirds.' },
  { title: 'Fast tomato salsa', channel: 'Slow Pan Kitchen', topic: 'food', tags: ['salsa', 'tomato', 'quick'], description: 'Chop, salt, lime, done.' },
  { title: 'Balcony herb hack', channel: 'Balcony Grower', topic: 'garden', tags: ['herbs', 'balcony', 'watering'], description: 'A bottle drip feeder for the hot weeks.' },
  { title: 'Tiny guitar riff of the day', channel: 'String Room', topic: 'music', tags: ['guitar', 'riff', 'practice'], description: 'Four notes, slowly, then up to speed.' },
  { title: 'Tram bell on the steep street', channel: 'Rail Window', topic: 'city', tags: ['tram', 'street', 'sound'], description: 'The bell, the hill and the squeal of the brakes.' },
  { title: 'Inbox zero in sixty seconds', channel: 'Desk Habits', topic: 'work', tags: ['email', 'productivity', 'habits'], description: 'Archive, reply or schedule: nothing else.' },
];

export interface PageItem { host: string; path: (r: () => number) => string; title: string; topic: Topic;
  tags: string[]; description: string; style: 'news' | 'recipe' | 'shop' | 'map' | 'page' }

const digits = (r: () => number, n: number) => Array.from({ length: n }, () => Math.floor(r() * 10)).join('');
const alnum = (r: () => number, n: number) => Array.from({ length: n }, () => 'abcdefghijklmnopqrstuvwxyz0123456789'[Math.floor(r() * 36)]).join('');
const slug = (s: string) => s.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');

function news(host: string, title: string, topic: Topic, tags: string[], description: string): PageItem {
  return { host, title, topic, tags, description, style: 'news',
    path: r => (host.includes('bbc') ? `/news/articles/c${alnum(r, 10)}` : `/world/2026/${slug(title)}-${digits(r, 4)}`) };
}
function recipe(host: string, title: string, tags: string[], description: string): PageItem {
  return { host, title, topic: 'food', tags, description, style: 'recipe',
    path: r => (host.includes('allrecipes') ? `/recipe/${digits(r, 6)}/${slug(title)}/` : `/recipes/${slug(title)}-${digits(r, 5)}`) };
}
function shop(host: string, title: string, topic: Topic, tags: string[], description: string): PageItem {
  return { host, title, topic, tags, description, style: 'shop',
    path: r => (host.includes('etsy') ? `/listing/${digits(r, 10)}/${slug(title)}` : `/pt/en/p/${slug(title)}-${digits(r, 8)}/`) };
}

export const PAGES: PageItem[] = [
  news('www.bbc.com', 'Night trams to run later on weekends', 'city', ['trams', 'transport', 'night'], 'The city extends weekend night services on four lines from next month.'),
  news('www.theguardian.com', 'Rainfall above average for October', 'city', ['weather', 'rain', 'autumn'], 'A wet month fills reservoirs and floods two riverside roads.'),
  news('www.bbc.com', 'New ferry timetable starts next month', 'travel', ['ferry', 'timetable', 'commute'], 'More crossings at rush hour and a later last boat.'),
  news('www.theguardian.com', 'Libraries to open on Sunday afternoons', 'reading', ['libraries', 'books', 'weekend'], 'A trial at six branches starts in December.'),
  news('www.reuters.com', 'Study finds short walks lift mood at work', 'fitness', ['walking', 'wellbeing', 'study'], 'Ten-minute walks between meetings made a measurable difference.'),
  news('www.reuters.com', 'Small bookshops report a busy autumn', 'reading', ['bookshops', 'books', 'retail'], 'Independent shops see more visitors than last year.'),
  recipe('www.allrecipes.com', 'Lemon olive oil cake', ['cake', 'lemon', 'baking'], 'A moist one-bowl cake with a sharp lemon glaze.'),
  recipe('www.bbcgoodfood.com', 'Chickpea and spinach stew', ['stew', 'chickpeas', 'vegetarian'], 'A smoky one-pot stew ready in thirty minutes.'),
  recipe('www.allrecipes.com', 'Roast pumpkin soup', ['soup', 'pumpkin', 'autumn'], 'Roasted pumpkin, onion and ginger blended smooth.'),
  recipe('www.bbcgoodfood.com', 'Grilled sardines with peppers', ['fish', 'sardines', 'grill'], 'Charred sardines on toast with sweet peppers.'),
  recipe('www.allrecipes.com', 'Custard tarts at home', ['pastry', 'custard', 'baking'], 'Crisp pastry cups with a burnt-sugar custard.'),
  recipe('www.bbcgoodfood.com', 'Banana bread with walnuts', ['banana', 'bread', 'baking'], 'Very ripe bananas, toasted walnuts and brown sugar.'),
  shop('www.etsy.com', 'Hand-thrown ceramic mug, sea green', 'shopping', ['mug', 'ceramics', 'gift'], 'A stoneware mug with a speckled sea-green glaze.'),
  shop('www.ikea.com', 'Folding wall desk, oak', 'home', ['desk', 'furniture', 'small space'], 'A wall-mounted desk that folds flat.'),
  shop('www.etsy.com', 'Linen curtains in sand', 'home', ['curtains', 'linen', 'bedroom'], 'Washed linen panels in a warm sand colour.'),
  shop('www.ikea.com', 'Brass reading lamp', 'shopping', ['lamp', 'lighting', 'reading'], 'A small clamp lamp with a brass shade.'),
  shop('www.etsy.com', 'Reflective running jacket', 'fitness', ['running', 'jacket', 'night'], 'A light shell with reflective panels for evening runs.'),
  { host: 'www.openstreetmap.org', title: 'Route to Lighthouse Gardens', topic: 'travel', tags: ['map', 'route', 'gardens'],
    description: 'A walking route along the river.', style: 'map', path: r => `/directions?route=${alnum(r, 6)}#map=16/38.70/-9.18` },
  { host: 'www.openstreetmap.org', title: 'Linden Garden and around', topic: 'city', tags: ['map', 'park', 'neighbourhood'],
    description: 'The garden, the bandstand and the streets around it.', style: 'map', path: () => '/#map=17/38.7139/-9.1597' },
  { host: 'maps.apple.com', title: 'Market hall', topic: 'city', tags: ['map', 'market', 'shopping'],
    description: 'Opening hours and directions to the market hall.', style: 'map', path: r => `/place?auid=${digits(r, 12)}` },
  { host: 'github.com', title: 'A tiny static site generator', topic: 'work', tags: ['code', 'website', 'tools'],
    description: 'Markdown in, plain HTML out, nothing else.', style: 'page', path: r => `/sample-lab/tiny-site-${alnum(r, 4)}` },
  { host: 'medium.com', title: 'Notes on deep work in small rooms', topic: 'work', tags: ['focus', 'work', 'habits'],
    description: 'An essay on doing careful work in a busy flat.', style: 'page', path: r => `/p/${alnum(r, 12)}` },
  { host: 'www.goodreads.com', title: "The Lighthouse Keeper's Year", topic: 'reading', tags: ['book', 'novel', 'to read'],
    description: 'A quiet novel about a year on a rocky coast.', style: 'page', path: r => `/book/show/${digits(r, 8)}` },
];

export const LINK_NOTES = ['Watch later', 'For the weekend', 'Try this one', 'Saved for later', 'Worth a look', 'Read on the train'];

// ---- notes and recordings ----

export interface TextItem { text: string; title: string; topic: Topic; tags: string[]; summary: string }

export const NOTES: TextItem[] = [
  { text: 'Groceries: lemons, olive oil, chickpeas, spinach, bread, coffee beans, bananas', title: 'Groceries for the week', topic: 'shopping', tags: ['groceries', 'list', 'food'], summary: 'A grocery list for the week.' },
  { text: 'Balcony ideas: lavender, a small lemon tree, two more pots, a drip tray for the fern', title: 'Balcony ideas', topic: 'garden', tags: ['balcony', 'plants', 'ideas'], summary: 'Plants and pots to add to the balcony.' },
  { text: 'Books to read: The Salt Road, Winter Orchard, A Year of Small Rooms', title: 'Books to read', topic: 'reading', tags: ['books', 'reading list', 'novels'], summary: 'Three novels to read next.' },
  { text: 'Meeting: move the launch to Thursday, draft the FAQ, check the budget with finance', title: 'Launch meeting notes', topic: 'work', tags: ['meeting', 'launch', 'budget'], summary: 'Decisions and actions from the launch meeting.' },
  { text: 'Run plan: Tuesday 5 km easy, Thursday intervals, Saturday long run by the river', title: 'Run plan for the week', topic: 'fitness', tags: ['running', 'plan', 'training'], summary: 'Three runs planned for the week.' },
  { text: 'Songs to learn: a slow waltz in D, the riff from the tram video, an old fado tune', title: 'Songs to learn', topic: 'music', tags: ['songs', 'guitar', 'practice'], summary: 'Songs to practise on the guitar.' },
  { text: 'Coast trip: train at 9:10, bring a jacket, lunch by the harbour, back before dark', title: 'Coast day trip plan', topic: 'travel', tags: ['trip', 'train', 'coast'], summary: 'Plan for a day trip to the coast by train.' },
  { text: 'Fix list: dripping tap, loose shelf in the hall, bathroom light, squeaky door', title: 'Things to fix at home', topic: 'home', tags: ['repairs', 'home', 'list'], summary: 'Small repairs to do at home.' },
  { text: 'Recipe idea: roast pumpkin with chilli, feta and toasted seeds', title: 'Roast pumpkin idea', topic: 'food', tags: ['recipe', 'pumpkin', 'idea'], summary: 'An idea for a roast pumpkin dish.' },
  { text: 'Gift ideas: ceramic mug, linen scarf, a fern in a nice pot, concert tickets', title: 'Gift ideas', topic: 'shopping', tags: ['gifts', 'ideas', 'list'], summary: 'Ideas for presents.' },
  { text: 'Places to see: Lighthouse Gardens at sunset, the tile workshop, the old market hall', title: 'Places to see in town', topic: 'city', tags: ['places', 'sightseeing', 'list'], summary: 'Places in town to visit.' },
  { text: 'Desk setup: raise the monitor, move the lamp left, add a cable tray, new chair cushion', title: 'Desk setup changes', topic: 'work', tags: ['desk', 'ergonomics', 'setup'], summary: 'Changes to make to the work desk.' },
  { text: 'Sleep: no screens after eleven, read a chapter instead, window open a little', title: 'Better sleep rules', topic: 'fitness', tags: ['sleep', 'habits', 'health'], summary: 'Rules for sleeping better.' },
  { text: 'Plant care: water the fern on Sundays, basil every other day, turn the orchid weekly', title: 'Plant care schedule', topic: 'garden', tags: ['plants', 'watering', 'schedule'], summary: 'When to water and turn each plant.' },
  { text: 'Weekend: market on Saturday morning, then the river walk, dinner at home', title: 'Weekend plan', topic: 'city', tags: ['weekend', 'market', 'walk'], summary: 'Plans for the weekend.' },
  { text: 'Budget: rent first, groceries 300, transport 40, savings 200, the rest for fun', title: 'Monthly budget', topic: 'home', tags: ['budget', 'money', 'month'], summary: 'A simple monthly budget.' },
  { text: 'Playlist for the drive: slow guitar, old fado, something upbeat for the motorway', title: 'Driving playlist ideas', topic: 'music', tags: ['playlist', 'driving', 'songs'], summary: 'Ideas for a playlist for a drive.' },
  { text: 'Packing: charger, passport, light jacket, walking shoes, the small umbrella', title: 'Packing list', topic: 'travel', tags: ['packing', 'travel', 'list'], summary: 'Things to pack for a trip.' },
  { text: 'Bread: 500 g flour, 350 g water, 10 g salt, starter fed at nine, bake at four', title: 'Bread recipe numbers', topic: 'food', tags: ['bread', 'baking', 'sourdough'], summary: 'Quantities and timings for a loaf of bread.' },
  { text: 'Quote from the talk: small steps every day beat big plans every month', title: 'Small steps quote', topic: 'work', tags: ['quote', 'habits', 'motivation'], summary: 'A quote about small daily steps.' },
  { text: 'Library: return the two novels, pick up the gardening book on hold', title: 'Library errands', topic: 'reading', tags: ['library', 'books', 'errands'], summary: 'Books to return and collect at the library.' },
  { text: 'Stretches: calves, hamstrings, hips, two minutes each after every run', title: 'Stretches after running', topic: 'fitness', tags: ['stretching', 'running', 'routine'], summary: 'A stretching routine after runs.' },
];

export const TRANSCRIPTS: TextItem[] = [
  { text: 'Remember to call about the bathroom tiles tomorrow morning and ask for the blue ones.', title: 'Call about the bathroom tiles', topic: 'home', tags: ['tiles', 'bathroom', 'reminder'], summary: 'A reminder to call about blue bathroom tiles.' },
  { text: 'Idea for the talk: start with the story about the lighthouse and end with the map.', title: 'Talk structure idea', topic: 'work', tags: ['talk', 'presentation', 'idea'], summary: 'An idea for how to open and close a talk.' },
  { text: 'Hum this later, it goes up on the third note and then falls back down slowly.', title: 'Melody to remember', topic: 'music', tags: ['melody', 'song', 'idea'], summary: 'A melody hummed to remember later.' },
  { text: 'Buy more coffee, the good beans, and pick up the shirts on the way home.', title: 'Coffee and shirts errand', topic: 'shopping', tags: ['errands', 'coffee', 'reminder'], summary: 'Errands for the way home.' },
  { text: 'The route along the river was lovely today, about six kilometres, try it again on Sunday.', title: 'River route run', topic: 'fitness', tags: ['running', 'river', 'route'], summary: 'A note about a good six-kilometre river route.' },
  { text: 'Note for the trip: the ferry leaves every half hour, the last one just before midnight.', title: 'Ferry times for the trip', topic: 'travel', tags: ['ferry', 'timetable', 'trip'], summary: 'Ferry times noted for a trip.' },
  { text: 'Soup idea: leftover pumpkin, ginger, a bit of coconut milk, blend it smooth.', title: 'Pumpkin soup idea', topic: 'food', tags: ['soup', 'pumpkin', 'recipe'], summary: 'An idea for a pumpkin and ginger soup.' },
  { text: 'Chapter three needs a better opening, maybe begin in the market at dawn.', title: 'Chapter three opening', topic: 'reading', tags: ['writing', 'chapter', 'idea'], summary: 'A thought about how to open chapter three.' },
  { text: 'Water the balcony plants twice this week, it is going to be warm and dry.', title: 'Water the balcony plants', topic: 'garden', tags: ['watering', 'balcony', 'weather'], summary: 'A reminder to water the plants more this week.' },
  { text: 'The square was full of music tonight, someone playing accordion by the fountain.', title: 'Accordion in the square', topic: 'city', tags: ['music', 'square', 'evening'], summary: 'A note about an accordion player in the square.' },
  { text: 'Ask about moving the weekly review to Friday afternoon, mornings are too busy.', title: 'Move the weekly review', topic: 'work', tags: ['meetings', 'schedule', 'review'], summary: 'A thought about moving the weekly review.' },
  { text: 'New lamp for the reading corner, warm light, something small that clamps on.', title: 'Lamp for the reading corner', topic: 'home', tags: ['lamp', 'reading corner', 'shopping'], summary: 'A note about a lamp for the reading corner.' },
  { text: 'The bakery by the garden has the custard tarts warm at eight, go early.', title: 'Warm custard tarts at eight', topic: 'food', tags: ['pastry', 'breakfast', 'tip'], summary: 'A tip about when the custard tarts are warm.' },
  { text: 'Train home was quiet, finished the second novel, the ending was a surprise.', title: 'Finished the second novel', topic: 'reading', tags: ['books', 'train', 'novel'], summary: 'A note about finishing a novel on the train.' },
];

export const VOICE_COMMENTS = ['Adding a thought: try this on the weekend.', 'Remember the price for next time.',
  'Show this to the others on Friday.', 'This one was better than I expected.'];

export const TEXT_COMMENTS = ['Tried it, worth it.', 'Still need to do this.', 'Went back on Sunday.', 'Done.', 'Price went down.',
  'Much better in person.', 'Saving this for the spring.', 'Second time, still good.'];

/** Sentences that put people in text. `{a}` and `{b}` are names. */
export const ONE_NAME = ['Send this to {a}.', '{a} recommended this.', 'Ask {a} about it.', 'Do this with {a} on Saturday.', '{a} would love this.'];
export const TWO_NAMES = ['{a} and {b} should see this.', 'Plan this with {a} and {b}.', 'From dinner with {a} and {b}.'];

// ---- pictures ----

export type SceneName = 'sunset' | 'tram' | 'fruit' | 'plant' | 'tiles' | 'books' | 'coffee' | 'beach' | 'night' | 'market' | 'park'
  | 'concert' | 'tarts' | 'boat' | 'desk';

export interface PhotoItem { scene: SceneName; titles: string[]; topic: Topic; tags: string[]; summary: string; description: string }

export const PHOTOS: PhotoItem[] = [
  { scene: 'sunset', titles: ['Sunset over the river', 'Orange sky by the bridge'], topic: 'travel', tags: ['sunset', 'river', 'bridge'], summary: 'A sunset over the river with the bridge in silhouette.',
    description: 'A sunset over a wide river, the sky fading from purple to orange with a low pale sun. A long suspension bridge stands dark against it and the light is reflected on the water in bands.' },
  { scene: 'tram', titles: ['Yellow tram on the hill', 'Tram climbing the street'], topic: 'city', tags: ['tram', 'street', 'hill'], summary: 'A yellow tram climbing a steep street.',
    description: 'A yellow tram with a white stripe climbs a steep street under an overhead wire. Pastel houses with small windows line the slope behind it under a blue sky.' },
  { scene: 'fruit', titles: ['Fruit bowl on the table', 'Oranges and bananas'], topic: 'food', tags: ['fruit', 'bananas', 'oranges'], summary: 'A bowl of oranges, bananas and an apple on a wooden table.',
    description: 'A white bowl on a wooden table holds oranges, a bunch of yellow bananas and a red apple. The wall behind is plain and softly lit.' },
  { scene: 'plant', titles: ['Plant on the windowsill', 'New leaves on the windowsill plant'], topic: 'garden', tags: ['plant', 'windowsill', 'pot'], summary: 'A leafy plant in a terracotta pot on a windowsill.',
    description: 'A leafy green plant in a terracotta pot sits on a white windowsill. Behind it a window with a cross frame shows a pale sky.' },
  { scene: 'tiles', titles: ['Tiled wall pattern', 'Painted tiles on a facade'], topic: 'city', tags: ['tiles', 'pattern', 'facade'], summary: 'A wall of painted tiles with a repeating pattern.',
    description: 'A close view of a wall covered in square painted tiles. Each tile has the same pattern of a central circle, a diamond and curved corners in one strong colour on white.' },
  { scene: 'books', titles: ['Bookshelf at the library', 'Shelf of new books'], topic: 'reading', tags: ['books', 'shelf', 'library'], summary: 'Three shelves full of colourful books.',
    description: 'Three wooden shelves packed with books of many colours and heights, their spines facing out. A small round vase stands at the end of one shelf.' },
  { scene: 'coffee', titles: ['Coffee at the cafe table', 'Morning coffee'], topic: 'food', tags: ['coffee', 'cafe', 'breakfast'], summary: 'A cup of coffee on a saucer seen from above.',
    description: 'Seen from above: a white cup of coffee with a light crema ring on a saucer with a spoon, next to a croissant on a round table.' },
  { scene: 'beach', titles: ['Afternoon at the beach', 'Umbrella by the sea'], topic: 'travel', tags: ['beach', 'sea', 'umbrella'], summary: 'A striped umbrella on a sandy beach by the sea.',
    description: 'A striped beach umbrella and a towel on pale sand, with blue sea and small white waves behind under a clear sky.' },
  { scene: 'night', titles: ['City lights at night', 'Rooftops under the moon'], topic: 'city', tags: ['night', 'city', 'moon'], summary: 'Dark rooftops with lit windows under a moon.',
    description: 'A night view of city buildings in silhouette with warm yellow lit windows. A round moon and a few stars are in the dark blue sky.' },
  { scene: 'market', titles: ['Vegetables at the market', 'Market stall colours'], topic: 'shopping', tags: ['market', 'vegetables', 'stall'], summary: 'Crates of tomatoes, peppers and lemons under a striped awning.',
    description: 'A market stall under a red and white striped awning, with wooden crates of red tomatoes, green peppers and yellow lemons.' },
  { scene: 'park', titles: ['Path through the park', 'Morning in the park'], topic: 'fitness', tags: ['park', 'trees', 'path'], summary: 'A curving path through green grass between round trees.',
    description: 'A sandy path curves through a green park between round trees, with a wooden bench beside it and a light blue sky above.' },
  { scene: 'concert', titles: ['Concert lights', 'Band on stage'], topic: 'music', tags: ['concert', 'stage', 'lights'], summary: 'Coloured spotlights over a stage and a crowd in silhouette.',
    description: 'A dark concert hall with coloured spotlight beams fanning down onto a stage. The heads and shoulders of the crowd are black silhouettes in the foreground.' },
  { scene: 'tarts', titles: ['Custard tarts', 'Tarts fresh from the oven'], topic: 'food', tags: ['pastry', 'custard tarts', 'bakery'], summary: 'Custard tarts with browned tops on a white plate.',
    description: 'A white plate on a blue table holds round custard tarts with crisp golden pastry and dark caramelised spots on top.' },
  { scene: 'boat', titles: ['Sailboat on the river', 'White sail on the water'], topic: 'travel', tags: ['sailboat', 'river', 'sailing'], summary: 'A small sailboat with a white sail on the river.',
    description: 'A small sailboat with a tall white triangular sail on calm blue water. The far shore is a low green line and a few birds fly overhead.' },
  { scene: 'desk', titles: ['Desk setup', 'Laptop and lamp at the desk'], topic: 'work', tags: ['desk', 'laptop', 'workspace'], summary: 'A desk with an open laptop, a lamp, a mug and a notebook.',
    description: 'A wooden desk against a plain wall with an open laptop showing a blue screen, an angled desk lamp, a mug and a closed notebook.' },
];

export type ScreenStyle = 'list' | 'chat' | 'weather' | 'transit' | 'order' | 'workout' | 'playlist' | 'calendar' | 'map';

export interface ScreenItem { style: ScreenStyle; heading: string; sub: string; rows: string[]; title: string; topic: Topic; tags: string[];
  summary: string; description: string; color: string }

export const SCREENS: ScreenItem[] = [
  { style: 'list', heading: 'Shopping', sub: '6 items', rows: ['Lemons', 'Olive oil', 'Chickpeas', 'Spinach', 'Bread', 'Bananas'], title: 'Shopping list screenshot', topic: 'shopping', tags: ['shopping list', 'groceries', 'list'], color: '#2f7d4f',
    summary: 'A screenshot of a shopping list with six items.', description: 'A phone screenshot of a list app with a green header titled "Shopping" and six rows: lemons, olive oil, chickpeas, spinach, bread and bananas, each with a round check box.' },
  { style: 'chat', heading: '{a}', sub: 'online', rows: ['Still on for Saturday?', 'Yes! Market at 10', 'Bring the big bag', 'And the list'], title: 'Chat about Saturday', topic: 'home', tags: ['chat', 'plans', 'weekend'], color: '#b5553c',
    summary: 'A chat screenshot making plans for the Saturday market.', description: 'A phone screenshot of a messaging app with a terracotta header showing a contact name. Grey and terracotta speech bubbles alternate, making plans to go to the market on Saturday at 10.' },
  { style: 'weather', heading: 'Lisboa', sub: '19° Sunny', rows: ['Now  19°', '15:00  20°', '18:00  18°', '21:00  16°', 'Tomorrow  17° rain'], title: 'Weather forecast screenshot', topic: 'city', tags: ['weather', 'forecast', 'sun'], color: '#f0a020',
    summary: 'A weather forecast screenshot showing a sunny afternoon.', description: 'A phone screenshot of a weather app with an orange header reading "Lisboa, 19° Sunny" and a big sun, followed by an hourly forecast list and rain tomorrow.' },
  { style: 'transit', heading: 'Line 7', sub: 'Departures', rows: ['08:12  Harbour Steps', '08:24  Harbour Steps', '08:36  Linden Garden', '08:48  Harbour Steps', '09:00  Long Lawn Park'], title: 'Line 7 departure times', topic: 'travel', tags: ['transit', 'timetable', 'commute'], color: '#ad1457',
    summary: 'A screenshot of departure times for line 7.', description: 'A phone screenshot of a transit app with a magenta header "Line 7 Departures" and a list of morning departure times with their destinations.' },
  { style: 'order', heading: 'Order placed', sub: 'Arrives Thursday', rows: ['Ceramic mug  18.00', 'Linen scarf  32.00', 'Delivery  4.50', 'Total  54.50'], title: 'Order confirmation', topic: 'shopping', tags: ['order', 'receipt', 'delivery'], color: '#6c4bd8',
    summary: 'A screenshot of an online order confirmation.', description: 'A phone screenshot of a shop order confirmation with a purple header "Order placed, arrives Thursday" and lines for a ceramic mug, a linen scarf, delivery and the total.' },
  { style: 'workout', heading: '5.2 km', sub: 'Morning run', rows: ['Time  28:41', 'Pace  5:31 /km', 'Climb  42 m', 'Heart  148 avg'], title: 'Morning run summary', topic: 'fitness', tags: ['running', 'workout', 'stats'], color: '#e4572e',
    summary: 'A screenshot of a 5.2 km morning run summary.', description: 'A phone screenshot of a workout summary with a large "5.2 km" in an orange-red header and rows for time, pace, climb and heart rate.' },
  { style: 'playlist', heading: 'Rainy Sunday', sub: '12 songs', rows: ['Slow Waltz in D', 'Harbour Lights', 'Paper Boats', 'The Long Road Home', 'Window Seat'], title: 'Rainy Sunday playlist', topic: 'music', tags: ['playlist', 'songs', 'music'], color: '#1e8c93',
    summary: 'A screenshot of a playlist called Rainy Sunday.', description: 'A phone screenshot of a music app with a teal header "Rainy Sunday, 12 songs" above a list of song titles, each with a square cover.' },
  { style: 'calendar', heading: 'Thursday', sub: '3 events', rows: ['09:30  Weekly review', '12:30  Lunch', '15:00  Launch call', '18:00  Guitar lesson'], title: 'Thursday calendar', topic: 'work', tags: ['calendar', 'schedule', 'meetings'], color: '#3949ab',
    summary: 'A screenshot of the calendar for Thursday.', description: 'A phone screenshot of a calendar day view with an indigo header "Thursday" and coloured event blocks for a weekly review, lunch, a launch call and a guitar lesson.' },
  { style: 'map', heading: 'Linden Garden', sub: '12 min walk', rows: ['Start  Harbour Steps', 'Walk  950 m'], title: 'Walking route to Linden Garden', topic: 'travel', tags: ['map', 'route', 'walking'], color: '#2e7d32',
    summary: 'A map screenshot with a walking route to Linden Garden.', description: 'A phone screenshot of a map app showing streets on a pale background, a blue walking route ending at a green pin, and a green header "Linden Garden, 12 min walk".' },
];

export interface ClipItem { note: string; title: string; topic: Topic; tags: string[]; summary: string }

export const CLIPS: ClipItem[] = [
  { note: 'Street musician by the fountain', title: 'Street musician by the fountain', topic: 'music', tags: ['busker', 'music', 'square'], summary: 'A short video of a street musician playing by a fountain.' },
  { note: 'Waves at the lighthouse', title: 'Waves at the lighthouse', topic: 'travel', tags: ['waves', 'sea', 'lighthouse'], summary: 'A short video of waves near a lighthouse.' },
  { note: 'Tram passing the square', title: 'Tram passing the square', topic: 'city', tags: ['tram', 'square', 'street'], summary: 'A short video of a tram crossing a square.' },
  { note: 'How the bread rose overnight', title: 'Bread dough rising', topic: 'food', tags: ['bread', 'dough', 'baking'], summary: 'A short video of risen bread dough.' },
  { note: 'Leaves blowing on the balcony', title: 'Leaves on the balcony', topic: 'garden', tags: ['leaves', 'wind', 'balcony'], summary: 'A short video of leaves blowing across a balcony.' },
];

export interface FileItem { name: string; type: 'pdf' | 'csv' | 'md'; lines: string[]; note: string; title: string; topic: Topic; tags: string[]; summary: string }

export const FILES: FileItem[] = [
  { name: 'Tram timetable autumn.pdf', type: 'pdf', lines: ['Line 7 autumn timetable', 'Weekdays every 12 minutes', 'Weekends every 20 minutes'], note: 'Timetable for the autumn', title: 'Autumn tram timetable', topic: 'travel', tags: ['timetable', 'tram', 'pdf'], summary: 'A PDF timetable for the autumn tram service.' },
  { name: 'Lemon cake recipe.pdf', type: 'pdf', lines: ['Lemon olive oil cake', '3 eggs, 200 g sugar, 120 ml olive oil', '2 lemons, 200 g flour'], note: 'The cake recipe to print', title: 'Lemon cake recipe', topic: 'food', tags: ['recipe', 'cake', 'pdf'], summary: 'A printable lemon cake recipe.' },
  { name: 'Workshop agenda.pdf', type: 'pdf', lines: ['Workshop agenda', '10:00 Welcome', '10:30 Small groups', '12:00 Wrap-up'], note: 'Agenda for the workshop on Thursday', title: 'Workshop agenda', topic: 'work', tags: ['agenda', 'workshop', 'pdf'], summary: 'The agenda for a Thursday workshop.' },
  { name: 'running-log-october.csv', type: 'csv', lines: ['date,km,minutes', '2026-10-04,5.0,29', '2026-10-11,7.5,44', '2026-10-18,6.2,35'], note: 'Running log for October', title: 'October running log', topic: 'fitness', tags: ['running', 'log', 'spreadsheet'], summary: 'A spreadsheet of runs in October.' },
  { name: 'budget-november.csv', type: 'csv', lines: ['item,amount', 'rent,750', 'groceries,300', 'transport,40'], note: 'Budget for November', title: 'November budget', topic: 'home', tags: ['budget', 'money', 'spreadsheet'], summary: 'A spreadsheet with the November budget.' },
  { name: 'trip-checklist.md', type: 'md', lines: ['# Trip checklist', '- charger', '- light jacket', '- walking shoes'], note: 'Checklist for the coast trip', title: 'Trip checklist', topic: 'travel', tags: ['checklist', 'trip', 'packing'], summary: 'A checklist for packing for a trip.' },
  { name: 'plant-care.md', type: 'md', lines: ['# Plant care', 'Fern: Sundays', 'Basil: every other day'], note: 'Plant care notes', title: 'Plant care notes', topic: 'garden', tags: ['plants', 'watering', 'notes'], summary: 'Notes on when to water each plant.' },
];

/** Topic colours for drawn link thumbnails. */
export const TOPIC_COLORS: Record<Topic, string> = {
  food: '#d9622b', travel: '#1f78b4', music: '#7b3fa0', home: '#8d6e63', work: '#37474f', reading: '#6d4c41', fitness: '#2e9e5b',
  shopping: '#c2185b', garden: '#558b2f', city: '#f2a900',
};
