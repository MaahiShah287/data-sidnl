create or replace function silver.selftest_parser()
returns text language plpgsql stable as $test$
declare
    p silver.pack_t;
begin
    assert silver.norm_key('Mr. Munchies')   = 'mr munchies',  'norm_key dotted';
    assert silver.norm_key('MR.MUNCHIES')    = 'mr munchies',  'norm_key upper';
    assert silver.norm_key('Mr.Munchies')    = 'mr munchies',  'norm_key no space';
    assert silver.norm_key('Lay''s')         = 'lays',         'norm_key apostrophe';
    assert silver.norm_key('Crunch & Munch') = 'crunch and munch', 'norm_key ampersand';
    assert silver.norm_key('   ')            is null,          'norm_key blank';
    assert silver.norm_key(null)             is null,          'norm_key null';

    assert silver.brand_matches('mr munchies', 'Mr. Munchies'),     'brand exact';
    assert silver.brand_matches('mr munchies', 'MrMunchies'),       'brand compact';
    assert silver.brand_matches('mr munchies', 'mr-munchies'),      'brand hyphen';
    assert not silver.brand_matches('mr munchies', 'Crunch & Munch'), 'brand must not substring-match';
    assert not silver.brand_matches('mr munchies', 'Nestle Munch'),   'brand must not substring-match 2';
    assert not silver.brand_matches('mr munchies', null),             'brand null';

    p := silver.parse_pack('270 g');
    assert (p.size_value, p.size_unit, p.pack_count) = (270, 'g', 1), 'pack 270 g';
    p := silver.parse_pack('1 pc (38.5 g)');
    assert (p.size_value, p.size_unit, p.pack_count) = (38.5, 'g', 1), 'pack 1 pc (38.5 g)';
    p := silver.parse_pack('330 ml');
    assert (p.size_value, p.size_unit, p.pack_count) = (330, 'ml', 1), 'pack 330 ml';
    p := silver.parse_pack('1 L');
    assert (p.size_value, p.size_unit, p.pack_count) = (1000, 'ml', 1), 'pack 1 L -> 1000 ml';
    p := silver.parse_pack('1.5 Ltr');
    assert (p.size_value, p.size_unit, p.pack_count) = (1500, 'ml', 1), 'pack 1.5 Ltr';
    p := silver.parse_pack('2 kg');
    assert (p.size_value, p.size_unit, p.pack_count) = (2000, 'g', 1), 'pack 2 kg';
    p := silver.parse_pack('6 x 330 ml');
    assert (p.size_value, p.size_unit, p.pack_count) = (330, 'ml', 6), 'pack 6 x 330 ml';
    p := silver.parse_pack('0,5 kg');
    assert (p.size_value, p.size_unit, p.pack_count) = (500, 'g', 1), 'pack decimal comma';
    p := silver.parse_pack('1 N');
    assert (p.size_value, p.size_unit, p.pack_count) = (1, 'pc', 1), 'pack 1 N';
    p := silver.parse_pack('3 pcs');
    assert (p.size_value, p.size_unit, p.pack_count) = (3, 'pc', 3), 'pack 3 pcs';
    p := silver.parse_pack(null);
    assert p.size_value is null and p.pack_count = 1, 'pack null';
    p := silver.parse_pack('assorted');
    assert p.size_value is null or p.size_unit = 'pc', 'pack junk does not crash';

    assert silver.parse_variant('Mr. Munchies Cheese Chilli Samosa (Frozen)', 'Mr. Munchies', 'Samosa') = 'Cheese Chilli', 'variant samosa';
    assert silver.parse_variant('Mr. Munchies Veg Spring Roll (Frozen)',      'Mr. Munchies', 'Spring Roll') = 'Veg', 'variant roll';
    assert silver.parse_variant('Mr. Munchies Spicy Frozen Paneer Bites',     'Mr. Munchies', 'Frozen Paneer Bites') = 'Spicy', 'variant paneer';
    assert silver.parse_variant('Mr. Munchies Lasooni Soya Chaap',            'Mr. Munchies', 'Soya Chaap') = 'Lasooni', 'variant chaap';
    assert silver.parse_variant('Mr. Munchies Samosa',                        'Mr. Munchies', 'Samosa') is null, 'variant empty -> null';

    assert silver.map_stock_status('in_stock')     = 'in_stock',     'state in';
    assert silver.map_stock_status('OUT_OF_STOCK') = 'out_of_stock', 'state out';
    assert silver.map_stock_status('not_listed')   = 'not_listed',   'state nl';
    assert silver.map_stock_status('weird')        = 'unknown',      'state unknown';
    assert silver.map_stock_status(null)           = 'unknown',      'state null';

    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,179,179)) = 'valid',   'dq clean';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'out_of_stock',0,null,null)) = 'valid', 'dq oos without price is valid';
    assert silver.dq_status(silver.reading_dq(true,false,now(),'in_stock',3,179,179)) = 'invalid', 'dq no store';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',-1,179,179)) = 'invalid', 'dq negative inv';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,200,179)) = 'suspect', 'dq sp > mrp';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,179,null)) = 'suspect', 'dq mrp missing';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'out_of_stock',4,179,179)) = 'suspect', 'dq oos with inventory';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'in_stock',3,null,null)) = 'suspect', 'dq in stock no price';
    assert silver.dq_status(silver.reading_dq(true,true,now() + interval '30 days','in_stock',3,179,179)) = 'invalid', 'dq future ts';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'weird',3,179,179)) = 'invalid', 'dq unknown state';
    assert silver.dq_status(silver.reading_dq(true,true,now(),'not_listed',null,null,null)) = 'valid', 'dq not_listed valid';
    return 'all parser tests passed';
end
$test$;