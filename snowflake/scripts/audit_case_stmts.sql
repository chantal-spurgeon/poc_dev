update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''0000'' THEN ''UNKNOWN''
WHEN book_name BETWEEN ''0001'' and ''0049'' THEN ''$1-$49''
WHEN book_name BETWEEN ''0050'' and ''0099'' THEN ''$50-$99''
WHEN book_name BETWEEN ''0100'' and ''0149'' THEN ''$100-$149''
WHEN book_name BETWEEN ''0150'' and ''0199'' THEN ''$150-$199''
WHEN book_name BETWEEN ''0200'' and ''0249'' THEN ''$200-$249''
WHEN book_name BETWEEN ''0250'' and ''0299'' THEN ''$250-$299''
WHEN book_name BETWEEN ''0300'' and ''0349'' THEN ''$300-$349''
WHEN book_name BETWEEN ''0350'' and ''0399'' THEN ''$350-$399''
WHEN book_name BETWEEN ''0400'' and ''0449'' THEN ''$400-$449''
WHEN book_name BETWEEN ''0450'' and ''0499'' THEN ''$450-$499''
WHEN book_name BETWEEN ''0500'' and ''0999'' THEN ''$500-$999''
WHEN book_name BETWEEN ''1000'' and ''1499'' THEN ''$1000-$1499''
WHEN book_name BETWEEN ''1500'' and ''2499'' THEN ''$1500-$2499''
WHEN book_name BETWEEN ''2500'' and ''2999'' THEN ''$2500-$2999''
WHEN book_name >= ''3000'' THEN ''$3000+''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('BAVGOFDL'
,'BAVGONDL'
,'BAVGDOLL'
,'BOFDOLLR'
,'BONDOLLR'
,'BTOTLDOL'
,'RDOLLARS'
);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''00'' THEN ''UNKNOWN''
WHEN book_name = ''01'' THEN ''01''
WHEN book_name = ''02'' THEN ''02''
WHEN book_name = ''03'' THEN ''03''
WHEN book_name = ''04'' THEN ''04''
WHEN book_name = ''05'' THEN ''05''
WHEN book_name BETWEEN ''06'' and ''09'' THEN ''06-09''
WHEN book_name BETWEEN ''10'' and ''14'' THEN ''10-14''
WHEN book_name BETWEEN ''15'' and ''20'' THEN ''15-20''
WHEN book_name BETWEEN ''21'' and ''24'' THEN ''21-24''
WHEN book_name >= ''25'' THEN ''25+''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('BOFORDER'
,'BONORDER'
,'BTOTLORD'
,'RORDERS'
);

--update dod_decode.data_dictionary
--set licensing_audit =
--replace(' CASE WHEN book_name BETWEEN ''000'' and ''017'' THEN ''0-17 YEARS OF AGE''
--WHEN book_name BETWEEN ''018'' and ''024'' THEN ''18-24 YEARS OF AGE''
--WHEN book_name BETWEEN ''025'' and ''029'' THEN ''25-29 YEARS OF AGE''
--WHEN book_name BETWEEN ''030'' and ''034'' THEN ''30-34 YEARS OF AGE''
--WHEN book_name BETWEEN ''035'' and ''039'' THEN ''35-39 YEARS OF AGE''
--WHEN book_name BETWEEN ''040'' and ''044'' THEN ''40-44 YEARS OF AGE''
--WHEN book_name BETWEEN ''045'' and ''049'' THEN ''45-49 YEARS OF AGE''
--WHEN book_name BETWEEN ''050'' and ''054'' THEN ''50-54 YEARS OF AGE''
--WHEN book_name BETWEEN ''055'' and ''059'' THEN ''55-59 YEARS OF AGE''
--WHEN book_name BETWEEN ''060'' and ''064'' THEN ''60-64 YEARS OF AGE''
--WHEN book_name BETWEEN ''065'' and ''069'' THEN ''65-69 YEARS OF AGE''
--WHEN book_name BETWEEN ''070'' and ''074'' THEN ''70-74 YEARS OF AGE''
--WHEN book_name >= ''075'' THEN ''75+ YEARS OF AGE''
--WHEN book_name = ''' || ''' THEN NULL
--\nELSE book_name ||'' - UNCODED~''
--\nEND'
--,'book_name', book_name)
--,special_rollup = 'Y'
--where book_name in
--('A_CALAGE'
--);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name BETWEEN ''00'' and ''17'' THEN ''0-17 YEARS OF AGE''
WHEN book_name BETWEEN ''18'' and ''24'' THEN ''18-24 YEARS OF AGE''
WHEN book_name BETWEEN ''25'' and ''29'' THEN ''25-29 YEARS OF AGE''
WHEN book_name BETWEEN ''30'' and ''34'' THEN ''30-34 YEARS OF AGE''
WHEN book_name BETWEEN ''35'' and ''39'' THEN ''35-39 YEARS OF AGE''
WHEN book_name BETWEEN ''40'' and ''44'' THEN ''40-44 YEARS OF AGE''
WHEN book_name BETWEEN ''45'' and ''49'' THEN ''45-49 YEARS OF AGE''
WHEN book_name BETWEEN ''50'' and ''54'' THEN ''50-54 YEARS OF AGE''
WHEN book_name BETWEEN ''55'' and ''59'' THEN ''55-59 YEARS OF AGE''
WHEN book_name BETWEEN ''60'' and ''64'' THEN ''60-64 YEARS OF AGE''
WHEN book_name BETWEEN ''65'' and ''69'' THEN ''65-69 YEARS OF AGE''
WHEN book_name BETWEEN ''70'' and ''74'' THEN ''70-74 YEARS OF AGE''
WHEN book_name >= ''75'' THEN ''75+ YEARS OF AGE''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('CALAGE'
);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''00'' THEN ''UNKNOWN YEARS OF AGE''
WHEN book_name BETWEEN ''00'' and ''18'' THEN ''0-18 YEARS OF AGE''
WHEN book_name BETWEEN ''19'' and ''25'' THEN ''19-25 YEARS OF AGE''
WHEN book_name BETWEEN ''26'' and ''30'' THEN ''26-30 YEARS OF AGE''
WHEN book_name BETWEEN ''31'' and ''35'' THEN ''31-35 YEARS OF AGE''
WHEN book_name BETWEEN ''36'' and ''40'' THEN ''36-40 YEARS OF AGE''
WHEN book_name BETWEEN ''41'' and ''45'' THEN ''41-45 YEARS OF AGE''
WHEN book_name BETWEEN ''46'' and ''50'' THEN ''46-50 YEARS OF AGE''
WHEN book_name BETWEEN ''51'' and ''55'' THEN ''51-55 YEARS OF AGE''
WHEN book_name BETWEEN ''56'' and ''60'' THEN ''55-60 YEARS OF AGE''
WHEN book_name BETWEEN ''61'' and ''65'' THEN ''61-65 YEARS OF AGE''
WHEN book_name BETWEEN ''66'' and ''70'' THEN ''66-70 YEARS OF AGE''
WHEN book_name BETWEEN ''71'' and ''75'' THEN ''71-75 YEARS OF AGE''
WHEN book_name BETWEEN ''76'' and ''99'' THEN ''76-99 YEARS OF AGE''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('C210MAH'
);

--update dod_decode.data_dictionary
--set licensing_audit =
--replace(' CASE WHEN book_name = ''00'' THEN ''UNKNOWN''
--WHEN book_name = ''01'' THEN ''01 YEAR''
--WHEN book_name = ''02'' THEN ''02 YEARS''
--WHEN book_name = ''03'' THEN ''03 YEARS''
--WHEN book_name = ''04'' THEN ''04 YEARS''
--WHEN book_name = ''05'' THEN ''05 YEARS''
--WHEN book_name = ''06'' THEN ''06 YEARS''
--WHEN book_name = ''07'' THEN ''07 YEARS''
--WHEN book_name = ''08'' THEN ''08 YEARS''
--WHEN book_name = ''09'' THEN ''09 YEARS''
--WHEN book_name = ''10'' THEN ''10 YEARS''
--WHEN book_name = ''15'' THEN ''15 YEARS''
--WHEN book_name = ''20'' THEN ''20 YEARS''
--WHEN book_name = ''25'' THEN ''25 YEARS''
--WHEN book_name = ''30'' THEN ''30 YEARS''
--WHEN book_name = ''40'' THEN ''40 YEARS''
--WHEN book_name = ''' || ''' THEN NULL
--\nELSE book_name ||'' - UNCODED~''
--\nEND'
--,'book_name', book_name)
--where book_name in
--('FMORTTRM'
--);

--update dod_decode.data_dictionary
--set licensing_audit =
--replace(' CASE WHEN book_name <> ''0'' THEN ''PRESENT''
--WHEN book_name = ''0'' THEN ''NOT PRESENT''
--WHEN book_name = ''' || ''' THEN NULL
--\nELSE book_name ||'' - UNCODED~''
--\nEND'
--,'book_name', book_name)
--,special_rollup = 'Y'
--where book_name in
--('PD_MORTTRM'
--);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN TRIM(book_name) <> '''||''' THEN ''PRESENT''
WHEN TRIM(book_name) = '''||''' THEN ''NOT PRESENT''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('TELE'
--,'PD_ORIGAPN'
--,'PD_LENDCD'
);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''000'' THEN ''$0''
WHEN book_name BETWEEN ''001'' and ''049'' THEN ''$1-$49999''
WHEN book_name BETWEEN ''050'' and ''099'' THEN ''$50000-$99999''
WHEN book_name BETWEEN ''100'' and ''149'' THEN ''$100000-$149999''
WHEN book_name BETWEEN ''150'' and ''199'' THEN ''$150000-$199999''
WHEN book_name BETWEEN ''200'' and ''249'' THEN ''$200000-$249999''
WHEN book_name BETWEEN ''250'' and ''299'' THEN ''$250000-$299999''
WHEN book_name BETWEEN ''300'' and ''349'' THEN ''$300000-$349999''
WHEN book_name BETWEEN ''350'' and ''399'' THEN ''$350000-$399999''
WHEN book_name BETWEEN ''400'' and ''449'' THEN ''$400000-$449999''
WHEN book_name BETWEEN ''450'' and ''499'' THEN ''$450000-$499999''
WHEN book_name BETWEEN ''500'' and ''749'' THEN ''$500000-$749999''
WHEN book_name >= ''750'' THEN ''$750000+''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('C210HVA'
);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''000'' THEN ''$0''
WHEN book_name BETWEEN ''001'' and ''014'' THEN ''Less than $15000''
WHEN book_name BETWEEN ''015'' and ''019'' THEN ''$15000-$19999''
WHEN book_name BETWEEN ''020'' and ''029'' THEN ''$20000-$29999''
WHEN book_name BETWEEN ''030'' and ''039'' THEN ''$30000-$39999''
WHEN book_name BETWEEN ''040'' and ''049'' THEN ''$40000-$49999''
WHEN book_name BETWEEN ''050'' and ''074'' THEN ''$50000-$74999''
WHEN book_name BETWEEN ''075'' and ''099'' THEN ''$75000-$99999''
WHEN book_name BETWEEN ''100'' and ''124'' THEN ''$100000-$124999''
WHEN book_name BETWEEN ''125'' and ''149'' THEN ''$125000-$149999''
WHEN book_name BETWEEN ''150'' and ''199'' THEN ''$150000-$199999''
WHEN book_name >= ''200'' THEN ''$200000+''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('C210EBI'
);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''000'' THEN ''$0''
WHEN book_name BETWEEN ''001'' and ''014'' THEN ''$1-14,999''
WHEN book_name BETWEEN ''015'' and ''019'' THEN ''$15-$19999''
WHEN book_name BETWEEN ''020'' and ''029'' THEN ''$20-$29999''
WHEN book_name BETWEEN ''030'' and ''039'' THEN ''$30-$39999''
WHEN book_name BETWEEN ''040'' and ''049'' THEN ''$40-$49999''
WHEN book_name BETWEEN ''050'' and ''074'' THEN ''$50-$74999''
WHEN book_name BETWEEN ''075'' and ''099'' THEN ''$75-$99999''
WHEN book_name BETWEEN ''100'' and ''124'' THEN ''$100-$124999''
WHEN book_name BETWEEN ''125'' and ''149'' THEN ''$125-$149999''
WHEN book_name BETWEEN ''150'' and ''199'' THEN ''$150-$199999''
WHEN book_name >= ''200'' THEN ''$200000+''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('C210HMI'
);

--update dod_decode.data_dictionary
--set licensing_audit =
--replace(' CASE WHEN book_name = ''0000'' THEN ''UNKNOWN''
--WHEN book_name BETWEEN ''0001'' and ''1960'' THEN ''1960 & BEFORE''
--WHEN book_name BETWEEN ''1961'' and ''1989'' THEN ''1961-1989''
--WHEN book_name BETWEEN ''1990'' and ''1999'' THEN ''1990-1999''
--WHEN book_name BETWEEN ''2000'' and ''2002'' THEN ''2000-2002''
--WHEN book_name BETWEEN ''2003'' and ''2004'' THEN ''2003-2004''
--WHEN book_name BETWEEN ''2005'' and ''2006'' THEN ''2005-2006''
--WHEN book_name BETWEEN ''2007'' and ''2008'' THEN ''2007-2008''
--WHEN book_name BETWEEN ''2009'' and ''2010'' THEN ''2009-2010''
--WHEN book_name = ''2011'' THEN ''2011''
--WHEN book_name = ''' || ''' THEN NULL
--\nELSE book_name ||'' - UNCODED~''
--\nEND'
--,'book_name', book_name)
--,special_rollup = 'Y'
--where book_name in
--('A_CSAG'
--);

--update dod_decode.data_dictionary
--set licensing_audit =
--replace(' CASE WHEN trim(book_name) = '''||''' THEN ''$0 - $0''
--WHEN book_name = ''00000000000'' THEN ''$0 - $0''
--WHEN book_name BETWEEN ''00000001000'' and ''00000049999'' THEN ''$1000 - $49999''
--WHEN book_name BETWEEN ''00000050000'' and ''00000099999'' THEN ''$50000 - $99999''
--WHEN book_name BETWEEN ''00000100000'' and ''00000149999'' THEN ''$100000 - $149999''
--WHEN book_name BETWEEN ''00000150000'' and ''00000199999'' THEN ''$150000 - $199999''
--WHEN book_name BETWEEN ''00000200000'' and ''00000249999'' THEN ''$200000 - $249999''
--WHEN book_name BETWEEN ''00000250000'' and ''00000299999'' THEN ''$250000 - $299999''
--WHEN book_name BETWEEN ''00000300000'' and ''00000349999'' THEN ''$300000 - $349999''
--WHEN book_name BETWEEN ''00000350000'' and ''00000399999'' THEN ''$350000 - $399999''
--WHEN book_name BETWEEN ''00000400000'' and ''00000449999'' THEN ''$400000 - $449999''
--WHEN book_name BETWEEN ''00000450000'' and ''00000499999'' THEN ''$450000 - $499999''
--WHEN book_name BETWEEN ''00000500000'' and ''00000999999'' THEN ''$500000 - $999999''
--WHEN book_name BETWEEN ''00001000000'' and ''00001499999'' THEN ''$1000000 - $1499999''
--WHEN book_name >= ''00001500000'' THEN ''$1500000+''
--WHEN book_name = ''' || ''' THEN NULL
--\nELSE book_name ||'' - UNCODED~''
--\nEND'
--,'book_name', book_name)
--,special_rollup = 'Y'
--where book_name in
--('PD_FMORT1'
--);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''0000'' THEN ''$0''
WHEN book_name BETWEEN ''0001'' and ''0049'' THEN ''$1000-$49999''
WHEN book_name BETWEEN ''0050'' and ''0099'' THEN ''$50000-$99999''
WHEN book_name BETWEEN ''0100'' and ''0149'' THEN ''$100000-$149999''
WHEN book_name BETWEEN ''0150'' and ''0199'' THEN ''$150000-$199999''
WHEN book_name BETWEEN ''0200'' and ''0249'' THEN ''$200000-$249999''
WHEN book_name BETWEEN ''0250'' and ''0299'' THEN ''$250000-$299999''
WHEN book_name BETWEEN ''0300'' and ''0349'' THEN ''$300000-$349999''
WHEN book_name BETWEEN ''0350'' and ''0399'' THEN ''$350000-$399999''
WHEN book_name BETWEEN ''0400'' and ''0449'' THEN ''$400000-$449999''
WHEN book_name BETWEEN ''0450'' and ''0499'' THEN ''$450000-$499999''
WHEN book_name BETWEEN ''0500'' and ''0749'' THEN ''$500000-$749999''
WHEN book_name BETWEEN ''0750'' and ''0999'' THEN ''$750000-$999999''
WHEN book_name >= ''1000'' THEN ''$1000000+''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('HMVLADD'
);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''0000'' THEN ''0%''
WHEN book_name BETWEEN ''0001'' and ''0029'' THEN ''01%-29%''
WHEN book_name BETWEEN ''0030'' and ''0049'' THEN ''30%-49%''
WHEN book_name BETWEEN ''0050'' and ''0074'' THEN ''50%-74%''
WHEN book_name BETWEEN ''0075'' and ''0099'' THEN ''75%-99%''
WHEN book_name BETWEEN ''0100'' and ''0124'' THEN ''100%-124%''
WHEN book_name BETWEEN ''0125'' and ''0149'' THEN ''125%-149%''
WHEN book_name >= ''0150'' THEN ''150+%''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('LNVLRTIO'
);

--update dod_decode.data_dictionary
--set licensing_audit =
--replace(' CASE WHEN trim(book_name) = '''||''' THEN ''$0 - $0''
--WHEN book_name = ''000000000'' THEN ''$0 - $0''
--WHEN book_name BETWEEN ''000001000'' and ''000049999'' THEN ''$1000 - $49999''
--WHEN book_name BETWEEN ''000050000'' and ''000099999'' THEN ''$50000 - $99999''
--WHEN book_name BETWEEN ''000100000'' and ''000149999'' THEN ''$100000 - $149999''
--WHEN book_name BETWEEN ''000150000'' and ''000199999'' THEN ''$150000 - $199999''
--WHEN book_name BETWEEN ''000200000'' and ''000249999'' THEN ''$200000 - $249999''
--WHEN book_name BETWEEN ''000250000'' and ''000299999'' THEN ''$250000 - $299999''
--WHEN book_name BETWEEN ''000300000'' and ''000349999'' THEN ''$300000 - $349999''
--WHEN book_name BETWEEN ''000350000'' and ''000399999'' THEN ''$350000 - $399999''
--WHEN book_name BETWEEN ''000400000'' and ''000449999'' THEN ''$400000 - $449999''
--WHEN book_name BETWEEN ''000450000'' and ''000499999'' THEN ''$450000 - $499999''
--WHEN book_name BETWEEN ''000500000'' and ''000999999'' THEN ''$500000 - $999999''
--WHEN book_name BETWEEN ''001000000'' and ''001499999'' THEN ''$1000000 - $1499999''
--WHEN book_name >= ''001500000'' THEN ''$1500000+''
--WHEN book_name = ''' || ''' THEN NULL
--\nELSE book_name ||'' - UNCODED~''
--\nEND'
--,'book_name', book_name)
--,special_rollup = 'Y'
--where book_name in
--('PD_MORTASSUM_AMT'
--);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''000'' THEN ''UNCODED''
WHEN book_name = ''001'' THEN ''1 PERSON IN HH''
WHEN book_name = ''002'' THEN ''2 PEOPLE IN HH''
WHEN book_name = ''003'' THEN ''3 PEOPLE IN HH''
WHEN book_name = ''004'' THEN ''4 PEOPLE IN HH''
WHEN book_name = ''005'' THEN ''5 PEOPLE IN HH''
WHEN book_name = ''006'' THEN ''6 PEOPLE IN HH''
WHEN book_name = ''007'' THEN ''7 PEOPLE IN HH''
WHEN book_name = ''008'' THEN ''8 PEOPLE IN HH''
WHEN book_name >= ''009'' THEN ''9+ PEOPLE IN HH''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
where book_name in
('NPH19'
);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''000'' THEN ''UNCODED''
WHEN book_name = ''001'' THEN ''1 ADULT IN HH''
WHEN book_name = ''002'' THEN ''2 ADULTS IN HH''
WHEN book_name = ''003'' THEN ''3 ADULTS IN HH''
WHEN book_name = ''004'' THEN ''4 ADULTS IN HH''
WHEN book_name = ''005'' THEN ''5 ADULTS IN HH''
WHEN book_name = ''006'' THEN ''6 ADULTS IN HH''
WHEN book_name = ''007'' THEN ''7 ADULTS IN HH''
WHEN book_name = ''008'' THEN ''8 ADULTS IN HH''
WHEN book_name >= ''009'' THEN ''9+ ADULTS IN HH''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
where book_name in
('NAH19'
);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''000'' THEN ''UNCODED''
WHEN book_name = ''001'' THEN ''1 CHILD IN HH''
WHEN book_name = ''002'' THEN ''2 CHILDREN IN HH''
WHEN book_name = ''003'' THEN ''3 CHILDREN IN HH''
WHEN book_name = ''004'' THEN ''4 CHILDREN IN HH''
WHEN book_name = ''005'' THEN ''5 CHILDREN IN HH''
WHEN book_name = ''006'' THEN ''6 CHILDREN IN HH''
WHEN book_name = ''007'' THEN ''7 CHILDREN IN HH''
WHEN book_name = ''008'' THEN ''8 CHILDREN IN HH''
WHEN book_name >= ''009'' THEN ''9+ CHILDREN IN HH''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
where book_name in
('NOC19'
--,'A_NOC19'
);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''001'' THEN ''1 SOURCE''
WHEN book_name = ''002'' THEN ''2 SOURCES''
WHEN book_name = ''003'' THEN ''3 SOURCES''
WHEN book_name = ''004'' THEN ''4 SOURCES''
WHEN book_name = ''005'' THEN ''5 SOURCES''
WHEN book_name = ''006'' THEN ''6 SOURCES''
WHEN book_name = ''007'' THEN ''7 SOURCES''
WHEN book_name = ''008'' THEN ''8 SOURCES''
WHEN book_name = ''009'' THEN ''9 SOURCES''
WHEN book_name BETWEEN ''010'' AND ''015'' THEN ''10-15 SOURCES''
WHEN book_name BETWEEN ''016'' AND ''020'' THEN ''16-20 SOURCES''
WHEN book_name BETWEEN ''021'' AND ''026'' THEN ''21-26 SOURCES''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('TINS'
);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''0'' THEN ''0 LOW RANK''
WHEN book_name = ''1'' THEN ''1''
WHEN book_name = ''2'' THEN ''2''
WHEN book_name = ''3'' THEN ''3''
WHEN book_name = ''4'' THEN ''4''
WHEN book_name = ''5'' THEN ''5''
WHEN book_name = ''6'' THEN ''6''
WHEN book_name = ''7'' THEN ''7''
WHEN book_name = ''8'' THEN ''8''
WHEN book_name = ''9'' THEN ''9 HIGH RANK''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
where book_name in
('ZINCDEC'
);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''0000'' THEN ''$0 - $0''
WHEN book_name BETWEEN ''0001'' and ''0049'' THEN ''$1000 - $49999''
WHEN book_name BETWEEN ''0050'' and ''0074'' THEN ''$50000 - $74999''
WHEN book_name BETWEEN ''0075'' and ''0099'' THEN ''$75000 - $99999''
WHEN book_name BETWEEN ''0100'' and ''0199'' THEN ''$100000 - $199999''
WHEN book_name BETWEEN ''0200'' and ''0299'' THEN ''$200000 - $299999''
WHEN book_name BETWEEN ''0300'' and ''0399'' THEN ''$300000 - $399999''
WHEN book_name BETWEEN ''0400'' and ''0499'' THEN ''$400000 - $499999''
WHEN book_name BETWEEN ''0500'' and ''0999'' THEN ''$500000 - $999999''
WHEN book_name BETWEEN ''0750'' and ''0999'' THEN ''$750000 - $999999''
WHEN book_name >= ''1000'' THEN ''$1000000+''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('Z4HMVALU'
);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN substring(book_name,0,4) = ''0000'' THEN ''UNKNOWN''
WHEN substring(book_name,0,4) BETWEEN ''0001'' and ''2007'' THEN ''2007 & BEFORE''
WHEN substring(book_name,0,4) = ''2008'' THEN ''2008''
WHEN substring(book_name,0,4) = ''2009'' THEN ''2009''
WHEN substring(book_name,0,4) = ''2010'' THEN ''2010''
WHEN substring(book_name,0,4) = ''2011'' THEN ''2011''
WHEN substring(book_name,0,4) = ''2012'' THEN ''2012''
WHEN substring(book_name,0,4) = ''2013'' THEN ''2013''
WHEN substring(book_name,0,4) = ''2014'' THEN ''2014''
WHEN substring(book_name,0,4) = ''2015'' THEN ''2015''
WHEN substring(book_name,0,4) = ''2016'' THEN ''2016''
WHEN substring(book_name,0,4) = ''2017'' THEN ''2017''
WHEN substring(book_name,0,4) = ''2018'' THEN ''2018''
WHEN substring(book_name,0,4) = ''2019'' THEN ''2019''
WHEN substring(book_name,0,4) = ''2020'' THEN ''2020''
WHEN book_name = ''202101'' THEN ''01/2021''
WHEN book_name = ''202102'' THEN ''02/2021''
WHEN book_name = ''202103'' THEN ''03/2021''
WHEN book_name = ''202104'' THEN ''04/2021''
WHEN book_name = ''202105'' THEN ''05/2021''
WHEN book_name = ''202106'' THEN ''06/2021''
WHEN book_name = ''202107'' THEN ''07/2021''
WHEN book_name = ''202108'' THEN ''08/2021''
WHEN book_name = ''202109'' THEN ''09/2021''
WHEN book_name = ''202110'' THEN ''10/2021''
WHEN book_name = ''202111'' THEN ''11/2021''
WHEN book_name = ''202112'' THEN ''12/2021''
WHEN book_name = ''202201'' THEN ''01/2022''
WHEN book_name = ''202202'' THEN ''02/2022''
WHEN book_name = ''202203'' THEN ''03/2022''
WHEN book_name = ''202204'' THEN ''04/2022''
WHEN book_name = ''202205'' THEN ''05/2022''
WHEN book_name = ''202206'' THEN ''06/2022''
WHEN book_name = ''202207'' THEN ''07/2022''
WHEN book_name = ''202208'' THEN ''08/2022''
WHEN book_name = ''202209'' THEN ''09/2022''
WHEN book_name = ''202210'' THEN ''10/2022''
WHEN book_name = ''202211'' THEN ''11/2022''
WHEN book_name = ''202212'' THEN ''12/2022''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('CNBC'
,'BDOC'
,'CACD'
--,'A_CDRG'
--,'FSALDATE'
--,'ISDT'
--,'ISDATEON'
--,'CPPD'
);

--update dod_decode.data_dictionary
--set licensing_audit =
--replace(' CASE WHEN substring(book_name,0,4) = ''0000'' THEN ''UNKNOWN''
--WHEN substring(book_name,0,4) between ''0001'' and ''1999'' THEN ''1999 & BEFORE''
--WHEN substring(book_name,0,4) between ''2000'' and ''2003'' THEN ''2000-2003''
--WHEN substring(book_name,0,4) between ''2004'' and ''2007'' THEN ''2004-2007''
--WHEN substring(book_name,0,4) = ''2008'' THEN ''2008''
--WHEN substring(book_name,0,4) = ''2009'' THEN ''2009''
--WHEN substring(book_name,0,4) = ''2010'' THEN ''2010''
--WHEN substring(book_name,0,4) = ''2011'' THEN ''2011''
--WHEN substring(book_name,0,4) = ''2012'' THEN ''2012''
--WHEN substring(book_name,0,4) = ''2013'' THEN ''2013''
--WHEN substring(book_name,0,4) = ''2014'' THEN ''2014''
--WHEN substring(book_name,0,4) = ''2015'' THEN ''2015''
--WHEN substring(book_name,0,4) = ''2016'' THEN ''2016''
--WHEN substring(book_name,0,4) = ''2017'' THEN ''2017''
--WHEN substring(book_name,0,4) = ''2018'' THEN ''2018''
--WHEN substring(book_name,0,4) = ''2019'' THEN ''2019''
--WHEN substring(book_name,0,4) = ''2020'' THEN ''2020''
--WHEN substring(book_name,0,4) = ''2021'' THEN ''2021''
--WHEN substring(book_name,0,4) = ''2022'' THEN ''2022''
--WHEN substring(book_name,0,4) = ''2023'' THEN ''2023''
--WHEN substring(book_name,0,4) = ''2024'' THEN ''2024''
--WHEN substring(book_name,0,4) = ''2025'' THEN ''2025''
--WHEN book_name = ''' || ''' THEN NULL
--\nELSE book_name ||'' - UNCODED~''
--\nEND'
--,'book_name', book_name)
--,special_rollup = 'Y'
--where book_name in
--('VH1PURDT'
--,'VH2PURDT'
--,'VH3PURDT'
--);

update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''0000'' THEN ''UNKNOWN''
WHEN book_name BETWEEN ''0800'' and ''0812'' THEN ''200800 - 200812''
WHEN book_name BETWEEN ''0900'' and ''0912'' THEN ''200900 - 200912''
WHEN book_name BETWEEN ''1000'' and ''1012'' THEN ''201000 - 201012''
WHEN book_name BETWEEN ''1100'' and ''1112'' THEN ''201100 - 201112''
WHEN book_name BETWEEN ''1200'' and ''1212'' THEN ''201200 - 201212''
WHEN book_name BETWEEN ''1300'' and ''1312'' THEN ''201300 - 201312''
WHEN book_name BETWEEN ''1400'' and ''1406'' THEN ''201400 - 201406''
WHEN book_name BETWEEN ''1407'' and ''1412'' THEN ''201407 - 201412''
WHEN book_name BETWEEN ''1500'' and ''1506'' THEN ''201500 - 201506''
WHEN book_name BETWEEN ''1507'' and ''1512'' THEN ''201507 - 201512''
WHEN book_name BETWEEN ''1600'' and ''1606'' THEN ''201600 - 201606''
WHEN book_name BETWEEN ''1607'' and ''1612'' THEN ''201607 - 201612''
WHEN book_name BETWEEN ''1700'' and ''1706'' THEN ''201700 - 201706''
WHEN book_name BETWEEN ''1707'' and ''1712'' THEN ''201707 - 201712''
WHEN book_name BETWEEN ''1800'' and ''1806'' THEN ''201800 - 201806''
WHEN book_name BETWEEN ''1807'' and ''1812'' THEN ''201807 - 201812''
WHEN book_name BETWEEN ''1900'' and ''1906'' THEN ''201900 - 201906''
WHEN book_name BETWEEN ''1907'' and ''1912'' THEN ''201907 - 201912''
WHEN book_name BETWEEN ''2000'' and ''2006'' THEN ''202000 - 202006''
WHEN book_name BETWEEN ''2007'' and ''2012'' THEN ''202007 - 202012''
WHEN book_name BETWEEN ''2100'' and ''2106'' THEN ''202100 - 202106''
WHEN book_name BETWEEN ''2107'' and ''2112'' THEN ''202107 - 202112''
WHEN book_name BETWEEN ''2200'' and ''2206'' THEN ''202200 - 202206''
WHEN book_name BETWEEN ''2207'' and ''2212'' THEN ''202207 - 202212''
WHEN book_name BETWEEN ''2300'' and ''2306'' THEN ''202300 - 202306''
WHEN book_name BETWEEN ''2307'' and ''2312'' THEN ''202307 - 202312''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('BLOFORDR'
,'BLONORDR'
,'BLSTORDR'
,'RORDERDT'
);


update dod_decode.data_dictionary
set licensing_audit =
replace(' CASE WHEN book_name = ''0000'' THEN ''UNKNOWN''
WHEN book_name BETWEEN ''0001'' and ''1960'' THEN ''1960 & BEFORE''
WHEN book_name BETWEEN ''1969'' and ''1989'' THEN ''1961-1989''
WHEN book_name BETWEEN ''1990'' and ''1999'' THEN ''1990-1999''
WHEN book_name BETWEEN ''2000'' and ''2002'' THEN ''2000-2002''
WHEN book_name BETWEEN ''2003'' and ''2004'' THEN ''2003-3004''
WHEN book_name BETWEEN ''2005'' and ''2006'' THEN ''2005-2006''
WHEN book_name BETWEEN ''2007'' and ''2008'' THEN ''2007-2008''
WHEN book_name = ''2009'' THEN ''2009''
WHEN book_name = ''2010'' THEN ''2010''
WHEN book_name = ''2011'' THEN ''2011''
WHEN book_name = ''2012'' THEN ''2012''
WHEN book_name = ''2013'' THEN ''2013''
WHEN book_name = ''2014'' THEN ''2014''
WHEN book_name = ''2015'' THEN ''2015''
WHEN book_name = ''2016'' THEN ''2016''
WHEN book_name = ''2017'' THEN ''2017''
WHEN book_name = ''2018'' THEN ''2018''
WHEN book_name = ''2019'' THEN ''2019''
WHEN book_name = ''2020'' THEN ''2020''
WHEN book_name = ''2021'' THEN ''2021''
WHEN book_name = ''2022'' THEN ''2022''
WHEN book_name = ''2023'' THEN ''2023''
WHEN book_name = ''2024'' THEN ''2024''
WHEN book_name = ''' || ''' THEN NULL
\nELSE book_name ||'' - UNCODED~''
\nEND'
,'book_name', book_name)
,special_rollup = 'Y'
where book_name in
('FEFFYRBL'
--,'FYEARBLT'
);

--update dod_decode.data_dictionary
--set licensing_audit =
--replace(' CASE WHEN book_name = ''0000'' THEN ''UNKNOWN''
--WHEN book_name BETWEEN ''1900'' and ''1979'' THEN ''1990-1979''
--WHEN book_name BETWEEN ''1980'' and ''1989'' THEN ''1980-1989''
--WHEN book_name BETWEEN ''1990'' and ''1999'' THEN ''1990-1999''
--WHEN book_name = ''2000'' THEN ''2000''
--WHEN book_name = ''2001'' THEN ''2001''
--WHEN book_name = ''2002'' THEN ''2002''
--WHEN book_name = ''2003'' THEN ''2003''
--WHEN book_name = ''2004'' THEN ''2004''
--WHEN book_name = ''2005'' THEN ''2005''
--WHEN book_name = ''2006'' THEN ''2006''
--WHEN book_name = ''2007'' THEN ''2007''
--WHEN book_name = ''2008'' THEN ''2008''
--WHEN book_name = ''2009'' THEN ''2009''
--WHEN book_name = ''2010'' THEN ''2010''
--WHEN book_name = ''2011'' THEN ''2011''
--WHEN book_name = ''2012'' THEN ''2012''
--WHEN book_name = ''2013'' THEN ''2013''
--WHEN book_name = ''2014'' THEN ''2014''
--WHEN book_name = ''2015'' THEN ''2015''
--WHEN book_name = ''2016'' THEN ''2016''
--WHEN book_name = ''2017'' THEN ''2017''
--WHEN book_name = ''2018'' THEN ''2018''
--WHEN book_name = ''2019'' THEN ''2019''
--WHEN book_name = ''2020'' THEN ''2020''
--WHEN book_name = ''2021'' THEN ''2021''
--WHEN book_name = ''2022'' THEN ''2022''
--WHEN book_name = ''2023'' THEN ''2023''
--WHEN book_name = ''2024'' THEN ''2024''
--WHEN book_name = ''' || ''' THEN NULL
--\nELSE book_name ||'' - UNCODED~''
--\nEND'
--,'book_name', book_name)
--,special_rollup = 'Y'
--where book_name in
--('VH1YEAR'
--,'VH2YEAR'
--,'VH3YEAR'
--);
