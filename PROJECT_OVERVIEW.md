# CitoStore – Vision USB Gateway (CM5)

## Projekt Áttekintés

A CitoStore egy intelligens, autonóm USB-alapú adatgyűjtő és tár-mirror megoldás, amely képfeldolgozó és ipari vizuális rendszerekhez lett tervezve. Az **ipari minősítésű Raspberry Pi CM5** mini-számítógépre telepítve **valós idejű adatgyűjtést, automatikus biztonsági mentést és hálózati megosztást** biztosít, feldolgozás közben.

Az eszköz **PoE+ (Power over Ethernet) táplálás** támogatással rendelkezik, így egyetlen Ethernet-kábel elegendő az adatátvitelhez és az áramellátáshoz. Igény szerint **WiFi csatlakozás** vagy **WiFi hotspot mód** is elérhető.

---

## A Probléma: Ipari Adatgyűjtés Meglévő Rendszerekben

A modern ipari környezetek általában **heterogén, szeparált hálózatokkal** működnek. Az egyes gépek és rendszerek – robotok, kamerás egységek, I/O vezérlés – saját, **alacsony latenciájú ipari Ethernet protokollokat** használnak (pl. Ethernet/IP, PROFINET, Modbus TCP). Ezek a hálózatok:

- **Kritikus teljesítményre vannak kihegyezve**: Az ipari folyamatok zavartalan működéséhez szükséges, hogy az I/O kommunikáció ultra-alacsony latenciájú maradjon
- **Több eszközt szolgálnak ki**: Egy megosztott hálózaton több fontos eszköz működik szimultán
- **Nem az adatgyűjtésre tervezték őket**: Az eredeti tervezéskor az adatok rögzítése nem volt prioritás

### A Kihívás

Ha az adatgyűjtést és -mentést ugyanarra a meglévő ipari hálózatra szerveznénk be, **nagy problémák jelentkeznek**:
- **Hálózati terhelés**: A kameraadatok és szinkronizáció százas-ezres MB/s-os átvitelt generálhat
- **Latencia növekedés**: Az ipari protokollok késésre érzékenyek; az adatmentés késleltetést okozhat
- **Rendszer instabilitás**: Az I/O vezérlés vagy robotikai mozgások zavara → termelési leállás

---

## Fő Képességek

### 1. **USB Mass Storage Interface**
- Az eszköz automatikusan USB-n keresztül egy **normális USB meghajtóként** jelenik meg a host eszköznek
- A host eszköz számára egyszerű plug-and-play élmény
- Nincsenek különleges illesztőprogramok vagy szoftverre van szükség
- Az adatok automatikusan szinkronizálódnak az NVMe-re, amint a host eszköz írja őket a USB-re – nincs szükség manuális indításra
- **FAT32 fájrendszer-emuláció**: Támogatja a régi szabványt, opcionálisan korlátozható a 4GB-os FAT32 limit (embedded rendszereknél gyakori megkötés) az ipari eszközökkel való kompatibilitás érdekében

### 2. **Valós Idejű Adatok Szinkronizálása**
- Az adatok automatikusan **NVMe SSD-re másolódnak** az eszközben (skálázható több TB szinten)
- **Intelligens stabilitás detekció**: Egy fájl csak akkor tekintendő kész-nek, ha kétszer egymás után ugyanolyan méret- és módosítási idővel olvassuk fel
- **Deduplikáció**: Azonos tartalmú fájlok csak egyszer tárolódnak
- **Szinkronizálási integrál**: 2-3 percenként futnak a szinkronizálási ciklusok (konfigurálható)
- **NVMe Automata Tárhelykezelés**: Az NVMe soha nem telik meg – ha a kihasználtság 85% felett van, a rendszer automata módon törli a legrégebbi szinkronizált adatokat, amíg a kihasználtság 70% alá nem csökken

### 3. **Automata Tárolási Rotáció**
- Az eszköz több logikai USB-kötetet kezel (LV) a tárhelyen
- Amikor az aktív meghajtó **megtelt**, az átváltás automatikusan megtörténik
- Az átváltás egy előre beállított ütemezési ablakban történik (és végszükség esetén azonnal)
- Az előző meghajtó offline feldolgozása:
  - Integritás-ellenőrzés (fsck)
  - Fennmaradó adatok szinkronizálása
  - Biztonsági törlés (opcionális)
  - Újraformázás az új ciklus előkészítéséhez
  - Bejelentkezési adatok helyreállítása (AOI beállítások)

### 4. **SMB/Samba Hálózati Megosztás**
- Az **tárolt adatok azonnal elérhetők a hálózaton** egy Windows/Mac/Linux megosztáson keresztül
- Felhasználónevekkel és jelszóval védett
- Az adatok **live módon elérhetők**, még az aktív szinkronizálás közben
- Ha az USB-meghajtó sérült vagy elveszett, az adatok továbbra is rendelkezésre állnak az SMB megosztáson
- **Mirror FTP (opcionális, csak olvasható)**: ugyanez az adat FTP-n keresztül is elérhető, azokra a klienskörnyezetekre, ahol az SMB nem elég stabil – **ugyanazzal a felhasználónévvel/jelszóval, mint az SMB megosztás**, külön hitelesítés bevezetése nélkül

### 5. **Opcionális NAS Biztonsági Másolat**
- Az összes szinkronizált adat **opcionálisan egy hálózati NAS-ra is másolható**
- Best-effort alapon működik – a hiba nem blokkolja a fő adatgyűjtést
- Külön hitelesítés támogatása (username/password/domain)
- Az adatok **duplán biztosak**: helyi NVMe + távoli NAS

### 6. **Webes Kezelő Felület (Web UI)**
Egy intuitív **böngészőben futó vezérlőpult**, amely teljes hozzáférést biztosít:

#### **Monitoring**
- Valós idejű szolgáltatás-állapot (USB gadget, szinkronizáció, rotáció)
- Hálózati állapot
- NVMe-tárhelyhasználat
- USB meghajtó terhelése
- Szinkronizálási statisztika

#### **Konfigurálás**
- **Szinkronizálási paraméterek**: Integrálás gyakoriságának, mélységének, hot-folder-szék beállítása
- **Samba beállítások**: NetBIOS-név, munkacsoportnév
- **NAS beállítások**: Aktiválás, elérési útvonalak, hitelesítési adatok
- **Hálózat**: DHCP vagy statikus IP-cím konfigurálása
- **Idő**: RTC-szinkronizálás és manuális időbeállítás

#### **Biztonság**
- WebUI jelszó módosítása
- SMB/Samba jelszó módosítása (ugyanez a jelszó érvényes az opcionális Mirror FTP-re is)
- Munkamenet-kezelés (8 órás TTL)

#### **Karbantartás**
- USB logikai kötet méretezése
- Tárolási kiegyenlítés
- Összes adat biztonságos törlése
- Alapértelmezések visszaállítása
- Biztonságos leállítás
- USB formátum klónozása

#### **Naplózás**
- Minden szolgáltatás naplóinak megtekintése
- Konfigurálható sormennyiség
- Valós idejű naplókeresés

---

## Rendszer Felépítés

A CitoStore két szeparált tárolási szinttel működik:

1. **USB Logikai Kötet (LV)** – A host eszköz ezt látja
   - A host eszköz (kamera, képfeldolgozó) közvetlenül erre írja az adatokat
   - Ez a "virtuális USB meghajtó", amelyet a host normál USB-ként lát
   - Az aktív LV sohasem kerül közvetlenül csatlakoztatásra – a szinkronizáció az LV-ből egy pillanatképet (snapshot) készít, amely csak olvasható

2. **NVMe Tárohely** – A valódi, hosszú táv adattárohely
   - Az adatok a szinkronizálási ciklus során másolódnak az USB LV-ből az NVMe-re
   - Ez az adatok végső helye, amely az SMB megosztáson és opcionális NAS-on is elérhetővé válik
   - Az NVMe soha nem telik meg – automata retention kezelés törli a legrégebbi adatokat szükség esetén

**Folyamat**: Host eszköz *(USB LV-re írás)* → CitoStore *(pillanatfelvétel + szinkronizálás)* → NVMe *(valódi tárohely)* → SMB/NAS *(hálózati elérhetőség)*

### A CitoStore Megoldása

A CitoStore **szeparált adatcsatornákat** használ, hogy **ne zavarja a meglévő ipari hálózatot**:

- **USB-alapú adatgyűjtés**: Direkt USB kapcsolat a vision host-tal → nincs hálózati terhelés
- **Hálózat-független**: Az adatok gyűjtése teljesen elkülönült az ipari Ethernet-től
- **Aszinkron szinkronizáció**: A szinkronizálás az SMB/NAS-ra külön időpontban, külön hálózati interfészen (PoE+) történik
- **Meglévő rendszerek zavartalan működése**: A robotok, I/O vezérlés és kamerás egységek továbbra is a saját, alacsony latenciájú hálózaton futnak

**Eredmény**: Ipari adatgyűjtés **nulla hálózati terhelés** mellett.

---

## Technikai Highlights

### **Hardver & Kapcsolatok**
- **Ipari minősítésű CM5**: Teljes körű megbízhatóság ipari környezetekhez
- **PoE+ táplálás**: Egyetlen Ethernet-kábel elegendő az adatátvitelhez és az áramellátáshoz – leegyszerűsített telepítés
- **WiFi csatlakozás**: Wireless hálózati csatlakozás támogatása
- **WiFi hotspot mód**: Az eszköz hotspotként is üzemelhet, ha az internet nem elérhető
- **Skálázható tárolóhely**: 100GB-tól több TB-ig, igény szerint bővíthető
- **NVMe tárolás**: WD Black 600 TBW/TB-vel szállítva (az 1TB-os SSD-t 600-szor teljesen felülírható) – skálázható nagyobb kapacitásra vagy más nagy teljesítménygel rendelkező NVMe-re

### **Megbízhatóság & Rugalmasság**
- **Read-only root filesystem**: Az operációs rendszer csak olvasható, az adatok sérülésétől védve
- **Szeparált tárolás**: Az operációs rendszer az eMMC-n van (csak olvasható), az adatok kizárólag az NVMe-re kerülnek – így az OS független az adattár terhelésétől és problémáitól
- **LVM-alapú tárolás**: Rugalmas logikai kötetek és snapshots
- **Thin provisioning**: Hatékony tárhely-kihasználás
- **Offline feldolgozás**: Az előző meghajtókat feldolgozzák, míg az új adat gyűjtés folytatódik
- **Automata helyreállítás**: Konfigurálható biztonsági másolatkezelés

### **Teljesítmény**
- **Pillanatképen alapuló szinkronizálás**: Az aktív USB meghajtót sohasem közvetlenül csatlakoztatja a rendszer, csak olvasható pillanatképeket használ az ütközések elkerüléséhez
- **Intelligens fájl-stabilitás**: Az írások közben nem másolódnak a fájlok
- **Depth-based targeting**: A szinkronizálási mélységet és gyakoriságát be lehet hangolni az igények szerint
- **Hot folder prioritás**: Az új könyvtárak előbb szinkronizálódnak

### **Üzemeltetés**
- **Nincs manuális beavatkozás szükséges**: Az eszköz teljesen automata
- **Konfigurálható riasztások**: A WebUI megjeleníti az eszköz állapotát
- **Naplózás**: Naplók helyileg tárolódnak a NVMe-en
- **Konfigurációs biztonsági másolatok**: "Shadow config" mechanizmus az alkalmazás előtt

---

## Tipikus Felhasználási Eset

1. A **vision host** (kamera/képfeldolgozó) képeket ír a CitoStore USB-meghajtójára
2. A CitoStore **automatikusan szinkronizálja** az adatokat az NVMe-re
3. Az adatok **azonnal elérhetők** az SMB megosztáson keresztül
4. Opcionálisan az adatok **NAS-ra is másolódnak**
5. Amikor az USB meghajtó megtelt, az **automata rotáció** új meghajtóra vált
6. Az előző meghajtó **offline feldolgozódik** és **újraformázódik**
7. A teljes folyamat **napi 24 órán keresztül** felügyelet nélkül működik

---

## Előnyök az Ügyfél Számára

**Automata adatmentés** – Napi 24 órán keresztül, felügyelet nélkül  
**Megbízható szinkronizáció** – Fájlok stabilitás-ellenőrzése, deduplikáció  
**Hálózati hozzáférés** – Azonnali adathozzáférés SMB-n keresztül  
**Csatornázott backup** – Opcionális NAS szinkronizáció  
**Automata helyreállítás** – Tárolási rotáció és újraformázás  
**Egyszerű kezelés** – Webes interfész, nincsenek parancssorűzések  
**Rugalmas beállítások** – Szinte minden paraméter módosítható  
**Megbízhatóság** – Read-only OS, offline feldolgozás, naplózás  
**Nulla hálózati terhelés** – Az ipari rendszerek függetlenek maradnak az adatgyűjtéstől

