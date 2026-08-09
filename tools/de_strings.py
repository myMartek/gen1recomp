#!/usr/bin/env python3
"""German for the text the engine writes itself.

These are keyed by the English source rather than by a cartridge label -- they
are this project's own Lua, not extracted ROM text -- so they are translated
here rather than read out of a dump. Placeholders (%s, %d, {RAM:...}, {PLAYER})
carry through untouched; a line that loses one loses the name it was going to
print.

Line breaks matter: \\n is a line inside the box, \\11 waits and scrolls, \\12
clears the box and waits. German is longer than English, so the breaks are
placed to fit the same box rather than copied across.
"""
import re
import sys
from pathlib import Path

T = {
    # ---- battle: what a move does ------------------------------------
    "%s\nflew up high!": "%s\nfliegt hoch!",
    "%s\ndug a hole!": "%s\ngräbt sich ein!",
    "%s\nmade a whirlwind!": "%s\nerzeugt einen\nWirbelsturm!",
    "%s\ntook in sunlight!": "%s\nsammelt Sonnen-\nlicht!",
    "%s\nlowered its head!": "%s\nsenkt den Kopf!",
    "%s\nis glowing!": "%s\nleuchtet auf!",
    "%s wants\nto fight!": "Ein wildes %s\nerscheint!",
    "%s wants\nto battle!": "%s\nfordert dich\nheraus!",
    "The GHOST\nappeared!": "Der GEIST\nerscheint!",
    "%s\nbecame confused!": "%s\nist verwirrt!",
    "%s\ncan't move!": "%s\nkann sich nicht\nbewegen!",
    "%s\ndid not learn%s!": "%s\nhat %s\nnicht erlernt!",
    "%s\nfainted!": "%s\nwurde besiegt!",
    "%s\nfell asleep!": "%s\nschläft ein!",
    "%s\nflinched!": "%s\nschreckt zurück!",
    "%s\ngained armor!": "%s\nist gepanzert!",
    "%s\nhas a SUBSTITUTE!": "%s\nhat einen\nDELEGATOR!",
    "%s\nis charging up!": "%s\nlädt auf!",
    "%s\nis confused!": "%s\nist verwirrt!",
    "%s\nis fast asleep!": "%s\nschläft tief!",
    "%s\nis frozen solid!": "%s\nist eingefroren!",
    "%s\nis refusing!": "%s\nverweigert sich!",
    "%s\nis revitalized!": "%s\nist gestärkt!",
    "%s\nis storing energy!": "%s\nspeichert Energie!",
    "%s\nis unaffected!": "%s\nbleibt unbeein-\ndruckt!",
    "%s\nkept going and\ncrashed!": "%s\nschießt vorbei\nund stürzt!",
    "%s\nran away scared!": "%s\nflieht voller\nAngst!",
    "%s\nran from battle!": "%s\nflieht aus dem\nKampf!",
    "%s\nregained health!": "%s\nerholt sich!",
    "%s\nsnapped out of\nconfusion!": "%s\nist nicht mehr\nverwirrt!",
    "%s\nstarted sleeping!": "%s\nschläft ein!",
    "%s\ntransformed into\n%s!": "%s\nverwandelt sich\nin %s!",
    "%s\nused %s!": "%s\nsetzt %s ein!",
    "%s\nwas afflicted\nby %s!": "%s\nleidet an %s!",
    "%s\nwas blown away!": "%s\nwird fortge-\nweht!",
    "%s\nwas burned!": "%s\nerleidet eine\nBrandwunde!",
    "%s\nwas frozen solid!": "%s\nist eingefroren!",
    "%s\nwas poisoned!": "%s\nwurde vergiftet!",
    "%s\nwas seeded!": "%s\nwurde besamt!",
    "%s\nwoke up!": "%s\nwacht auf!",
    "%s blacked\nout!": "%s\nwurde besiegt!",
    "%s can't\nlearn that move!": "%s kann diese\nAttacke nicht\nerlernen!",
    "%s found\n%d coins!": "%s findet\n%d Münzen!",
    "%s found\n%s!": "%s findet\n%s!",
    "%s gained\n%d EXP. Points!": "%s erhält\n%d E-Punkte!",
    "%s gained\na boosted%d EXP. Points!": "%s erhält\nerhöhte %d\nE-Punkte!",
    "%s gained\nwith EXP.ALL,%d EXP. Points!": "%s erhält mit\nEP-TEILER\n%d E-Punkte!",
    "%s got off\nthe BICYCLE.": "%s steigt vom\nFAHRRAD.",
    "%s got on\nthe BICYCLE!": "%s steigt aufs\nFAHRRAD!",
    "%s grew\nto level %d!": "%s erreicht\nLevel %d!",
    "%s has no\nmoves left!": "%s hat keine\nAttacken mehr!",
    "%s is\nabout to use%s!": "%s wird gleich\n%s einsetzen!",
    "%s is\nalready out!": "%s ist bereits\nim Kampf!",
    "%s is\nprotected by MIST!": "%s wird von\nWEISSNEBEL\ngeschützt!",
    "%s is too\nscared to move!": "%s ist zu ver-\nängstigt!",
    "%s learned\n%s!": "%s erlernt\n%s!",
    "%s left the\nbattle.": "%s verlässt den\nKampf.",
    "%s played the\nPOKé FLUTE.": "%s spielt auf der\nPOKéFLÖTE.",
    "%s ran from\nthe battle!": "%s flieht aus dem\nKampf!",
    "%s received\n%s!": "%s erhält\n%s!",
    "%s received\nthe %s!": "%s erhält\n%s!",
    "%s saved\nthe game!": "%s hat gespeichert!",
    "%s sent\nout %s!": "%s setzt\n%s ein!",
    "%s used\n%s!": "%s setzt\n%s ein!",
    "%s used\nPOKé BALL!": "%s wirft einen\nPOKéBALL!",
    "%s used\nSAFARI BALL!": "%s wirft einen\nSAFARIBALL!",
    "%s with-\ndrew %s!": "%s ruft\n%s zurück!",
    "%s's\n%s\ngreatly fell!": "%s'\n%s\nsinkt stark!",
    "%s's\n%s\ngreatly rose!": "%s'\n%s\nsteigt stark!",
    "%s's\n%s fell!": "%s'\n%s sinkt!",
    "%s's\n%s rose!": "%s'\n%s steigt!",
    "%s's\n%s was\ndisabled!": "%s'\n%s wurde\nblockiert!",
    "%s's\nattack missed!": "%s'\nAngriff geht\ndaneben!",
    "%s's\nbadly poisoned!": "%s ist schwer\nvergiftet!",
    "%s's\ndisabled no more!": "%s ist nicht mehr\nblockiert!",
    "%s's\ndream was eaten!": "%s' Traum wurde\ngefressen!",
    "%s's\nfully paralyzed!": "%s ist voll\nparalysiert!",
    "%s's\ngetting pumped!": "%s macht sich\nbereit!",
    "%s's\nhit with recoil!": "%s nimmt Rück-\nstoßschaden!",
    "%s's\nhits will never\nmiss!": "%s trifft von\nnun an immer!",
    "%s's\nhurt by poison!": "%s leidet unter\nder Vergiftung!",
    "%s's\nhurt by the burn!": "%s leidet unter\nder Brandwunde!",
    "%s's\nparalyzed! It may\nnot attack!": "%s ist paraly-\nsiert und kann\nvielleicht nicht\nangreifen!",
    "%s's\nprotected against\nspecial attacks!": "%s ist gegen\nSpezialangriffe\ngeschützt!",
    "%s's\nprotected against\nstat changes!": "%s ist gegen\nStatusänderungen\ngeschützt!",
    "%s's\nshrouded in mist!": "%s ist in Nebel\ngehüllt!",
    "%s's\nstatus returned\nto normal!": "%s ist wieder\nwohlauf!",
    "%s's %s\nrose!": "%s'\n%s steigt!",
    "%s's HP\nwas restored!": "%s' KP wurden\naufgefüllt!",
    "%s's PP\nincreased!": "%s' AP wurden\nerhöht!",
    "%s's PP\nwas restored!": "%s' AP wurden\naufgefüllt!",
    "Critical hit!": "Ein Volltreffer!",
    "It's super\neffective!": "Das ist sehr\neffektiv!",
    "It's not very\neffective...": "Das ist nicht\nsehr effektiv...",
    "It didn't affect\n%s!": "Es hat keine\nWirkung auf %s!",
    "It doesn't affect\n%s!": "Es hat keine\nWirkung auf %s!",
    "No effect!": "Keine Wirkung!",
    "One-hit KO!": "Ein K.o.-Treffer!",
    "But, it failed!": "Es ist fehl-\ngeschlagen!",
    "Nothing happened!": "Nichts geschieht!",
    "Hit %d times!": "%d Treffer!",
    "Hit the enemy\n%d times!": "Der Gegner wurde\n%d mal getroffen!",
    "The MIRROR MOVE\nfailed!": "SPIEGELTRICK ist\nfehlgeschlagen!",
    "It created a\nSUBSTITUTE!": "Ein DELEGATOR\nist entstanden!",
    "Too weak to make\na SUBSTITUTE!": "Zu schwach für\neinen DELEGATOR!",
    "Sucked health from\n%s!": "%s wurde Energie\nentzogen!",
    "LEECH SEED saps\n%s!": "EGELSAMEN saugt\n%s aus!",
    "Fire defrosted\n%s!": "Das Feuer taut\n%s auf!",
    "All STATUS changes\nare eliminated!": "Alle Status-\nänderungen sind\naufgehoben!",
    "All sleeping\nPOKéMON woke up!": "Alle schlafenden\nPOKéMON wachen\nauf!",
    "Converted type to\n%s's!": "Typ zu dem von\n%s geändert!",
    "The wild POKéMON\nran away!": "Das wilde POKéMON\nist geflohen!",
    "This POKéMON\ncan't be caught!": "Dieses POKéMON\nkann nicht ge-\nfangen werden!",
    "There's no will\nto fight!": "Es besteht kein\nKampfeswille!",
    "No! There's no\nrunning from atrainer battle!": "Nein! Aus einem\nTrainerkampf\nkann man nicht\nfliehen!",
    "Use next POKéMON?": "Nächstes POKéMON\neinsetzen?",
    "Will %s\nchange POKéMON?": "Wechselt %s\ndas POKéMON?",
    "Do it! %s!": "Los, %s!",
    "Go! %s!": "Los, %s!",
    "Get'm! %s!": "Schnapp sie dir,\n%s!",
    "Keep it up!": "Weiter so!",
    "Go right ahead!": "Nur zu!",
    "Gyaoo!": "Gyaoo!",

    # ---- catching ----------------------------------------------------
    "All right!\n%s was\ncaught!": "Sehr gut!\n%s wurde\ngefangen!",
    "Darn! The POKéMON\nbroke free!": "Mist! Das POKéMON\nhat sich befreit!",
    "It dodged the\nthrown BALL!": "Es weicht dem\nBALL aus!",
    "You missed the\nPOKéMON!": "Du hast das\nPOKéMON verfehlt!",
    "New POKéDEX data\nwill be added for\n%s!": "Neue POKéDEX-\nDaten für %s\nwerden ergänzt!",
    "There's no more\nroom for POKéMON!%s wassent to POKéMONBOX %s on PC!": "Kein Platz mehr\nfür POKéMON!\n%s wurde in\nPOKéMON-BOX %s\nauf dem PC\ngelagert!",

    # ---- levelling and evolution ------------------------------------
    "What?\n%s is\nevolving!Congratulations!\nYour %s\nevolved into\n%s!": "Was?\n%s\nentwickelt sich!\nGlückwunsch!\nDein %s\nwurde zu\n%s!",
    "Congratulations!\nYour %s\nevolved into\n%s!": "Glückwunsch!\nDein %s\nwurde zu\n%s!",
    "Huh? %s\nstopped evolving!": "Wie? %s\nentwickelt sich\ndoch nicht!",
    "Delete an older\nmove to make roomfor %s?": "Eine ältere\nAttacke löschen,\num Platz für\n%s zu schaffen?",
    "Abandon learning\n%s?": "Das Erlernen von\n%s abbrechen?",
    "It knows that\nmove already!": "Diese Attacke\nkennt es bereits!",
    "HM techniques\ncan't be deleted!": "VM-Attacken\nkönnen nicht\ngelöscht werden!",
    "be forgotten?": "vergessen werden?",
    "Which move should": "Welche Attacke soll",
    "NOT ABLE": "NICHT MÖGLICH",
    "ABLE": "MÖGLICH",

    # ---- items -------------------------------------------------------
    "It contained\n%s!": "Darin war\n%s!",
    "It won't have\nany effect.": "Das hat keine\nWirkung.",
    "Booted up a TM!": "Eine TM wurde\ngestartet!",
    "Use TM on which\nPOKéMON?": "Bei welchem\nPOKéMON soll die\nTM benutzt\nwerden?",
    "Use on which one?": "Bei welchem?",
    "Toss %s?": "%s wegwerfen?",
    "Threw away\n%s.": "%s wurde\nweggeworfen.",
    "Threw away %s.": "%s wurde weggeworfen.",
    "That's too impor-\ntant to toss!": "Das ist zu\nwichtig zum\nWegwerfen!",
    "You can't carry\nany more items!": "Du kannst keine\nweiteren Items\ntragen!",
    "You can't carry\nany more items.": "Du kannst keine\nweiteren Items\ntragen.",
    "No room left to\nstore items.": "Kein Platz mehr\nfür Items.",
    "Withdrew\n%s.": "%s wurde\nentnommen.",
    "Items can't be\nused in a link\nbattle!": "Im Kampf über\nKabel können\nkeine Items\nbenutzt werden!",
    "OAK: %s!\nThis isn't the\ntime to use that!": "EICH: %s!\nJetzt ist nicht\nder richtige\nZeitpunkt dafür!",
    "REPEL's effect\nwore off.": "Die Wirkung von\nSCHUTZ lässt\nnach.",
    "%s?\nThat will be\n¥%d. OK?": "%s?\nDas macht\n¥%d. Einver-\nstanden?",
    "I can pay you\n¥%d for that.": "Dafür zahle ich\ndir ¥%d.",
    "I can't put a\nprice on that.": "Dafür kann ich\nkeinen Preis\nnennen.",
    "You don't have\nenough money.": "Du hast nicht\ngenug Geld.",
    "You don't have\nany coins!": "Du hast keine\nMünzen!",
    "Not enough\ncoins!": "Nicht genug\nMünzen!",
    "Darn!\nRan out of coins!": "Mist!\nKeine Münzen\nmehr!",
    "Coin count:\n%d": "Münzen:\n%d",
    "Coins scattered\neverywhere!": "Überall liegen\nMünzen!",
    "%s lined up!\nScored %d coins!": "%s in einer\nReihe!\n%d Münzen!",
    "Bingo!": "Bingo!",
    "A COIN CASE is\nrequired!": "Eine MÜNZKISTE\nwird benötigt!",

    # ---- the world ---------------------------------------------------
    "Nothing to CUT!": "Hier gibt es\nnichts zu\nZERSCHNEIDERN!",
    "No SURFing here!": "Hier kann man\nnicht SURFEN!",
    "No cycling\nallowed here.": "Radfahren ist\nhier nicht\nerlaubt.",
    "You need a\nBICYCLE for the\nCycling Road!": "Für den RADWEG\nbrauchst du ein\nFAHRRAD!",
    "You can't get off\nhere.": "Hier kannst du\nnicht absteigen.",
    "No good! It's not\neven near water.": "Nichts zu machen!\nHier ist kein\nWasser in der\nNähe.",
    "Not even a nibble!": "Nicht mal ein\nAnbiss!",
    "Oh!\nIt's a bite!": "Oh!\nEs beißt an!",
    "What? There are\nno POKéMON here!": "Was? Hier gibt es\nkeine POKéMON!",
    "Nothing here.": "Hier ist nichts.",
    "The boulder fell\nthrough the hole!": "Der Felsen fällt\ndurch das Loch!",
    "Move to where?": "Wohin?",
    "The TOWN MAP is\nunreadable here.": "Die STADTKARTE\nist hier nicht\nlesbar.",
    "An elevator!": "Ein Aufzug!",
    "Yes! ITEMFINDER\nindicates there's\nan item nearby.": "Ja! Der ITEMSUCHER\nzeigt an, dass\nhier ein Item in\nder Nähe ist.",
    "Nope! ITEMFINDER\nisn't responding.": "Nein! Der ITEM-\nSUCHER schlägt\nnicht an.",
    "Nope, there's\nonly trash here.": "Nein, hier ist\nnur Müll.",
    "Nope! There's\nonly trash here.Hey! The electric\nlocks were reset!": "Nein, hier ist\nnur Müll.\nHey! Die elek-\ntrischen Schlösser\nwurden zurück-\ngesetzt!",
    "\nThe CARD KEY\nopened the door!": "\nDie KARTENKEY\nöffnet die Tür!",
    "Darn! It needs a\nCARD KEY!": "Mist! Dafür\nbraucht man eine\nKARTENKEY!",
    "Hey! There's a\nswitch under the\ntrash!The 1st electric\nlock opened!": "Hey! Unter dem\nMüll ist ein\nSchalter!\nDas 1. elek-\ntrische Schloss\nist offen!",
    "The 2nd electric\nlock opened!The motorized door\nopened!": "Das 2. elek-\ntrische Schloss\nist offen!\nDie Tür öffnet\nsich!",
    "A blinding FLASH\nlights the area!": "Ein greller BLITZ\nerhellt die\nUmgebung!",
    "SILPH SCOPE\nunveiled theGHOST's identity!": "Der SILPH-SCOPE\nenthüllt, wer der\nGEIST wirklich\nist!",
    "Played the POKé\nFLUTE.Now, that's a\ncatchy tune!": "Auf der POKéFLÖTE\ngespielt.\nEine eingängige\nMelodie!",
    "TELEPORTER is\ndisplayed on the\nPC monitor.": "TELEPORTER wird\nauf dem Monitor\nangezeigt.",
    "It's a sculpture\nof DIGLETT.": "Eine Skulptur\nvon DIGDA.",
    "There's a slew of\nPOKéMON stuff!": "Jede Menge\nPOKéMON-Kram!",
    "Crammed full of\nPOKéMON books!": "Vollgestopft mit\nPOKéMON-Büchern!",
    "Data unknown.": "Daten unbekannt.",
    "Empty.": "Leer.",
    "What?": "Was?",
    "Someone's keys!\nThey'll be back.": "Jemandes\nSchlüssel! Er\nkommt sicher\nzurück.",
    "OUT OF ORDER\nThis is broken.": "AUSSER BETRIEB\nDefekt.",
    "OUT TO LUNCH\nThis is reserved.": "MITTAGSPAUSE\nReserviert.",

    # ---- centre, PC, saving ------------------------------------------
    "Welcome to our\nPOKéMON CENTER!": "Willkommen im\nPOKéMON-CENTER!",
    "Shall we heal your\nPOKéMON?": "Sollen wir deine\nPOKéMON heilen?",
    "Your POKéMON are\nfighting fit!": "Deine POKéMON\nsind wieder\nkampfbereit!",
    "We hope to see\nyou again!": "Bis zum nächsten\nMal!",
    "Please come\nagain!": "Komm bald wieder!",
    "Hi there!\nMay I help you?": "Hallo! Kann ich\ndir helfen?",
    "Here you are!\nThank you!": "Bitte sehr!\nVielen Dank!",
    "OK. We'll need\nyour POKéMON.": "Gut. Wir brauchen\ndeine POKéMON.",
    "We're making\npreparations.Please wait.": "Wir bereiten\nalles vor.\nBitte warte.",
    "Would you like to\nSAVE the game?": "Möchtest du das\nSpiel SPEICHERN?",
    "Now saving...": "Speichert...",
    "When you change a\nPOKéMON BOX, data\nwill be saved. OK?": "Beim Wechsel der\nPOKéMON-BOX wird\ngespeichert.\nEinverstanden?",
    "Oops! This Box is\nfull of POKéMON.": "Ups! Diese Box\nist voller\nPOKéMON.",
    "But every BOX\nis full!": "Aber jede BOX\nist voll!",
    "You can't deposit\nthe last POKéMON!": "Du kannst das\nletzte POKéMON\nnicht abgeben!",
    "You can't take\nany more POKéMON.Deposit POKéMON\nfirst.": "Du kannst keine\nweiteren POKéMON\nnehmen. Lagere\nzuerst welche\nein.",
    "There's no more\nroom for POKéMON!": "Kein Platz mehr\nfür POKéMON!",
    "Once released,\n%s is\ngone forever. OK?": "Einmal frei-\ngelassen ist\n%s für immer\nfort. Sicher?",
    "%s was\nreleased outside.Bye %s!": "%s wurde frei-\ngelassen.\nLeb wohl, %s!",
    "%s was\nstored in Box %s.": "%s wurde in\nBox %s gelagert.",
    "%s was\nstored via PC.": "%s wurde über\nden PC gelagert.",
    "%s is\ntaken out.Got %s.": "%s wird ent-\nnommen.\n%s erhalten.",
    "Accessed PROF.\nOAK's PC.Accessed POKéDEX\nRating System.": "Auf PROF. EICHs\nPC zugegriffen.\nPOKéDEX-Bewer-\ntung geöffnet.",
    "Closed link to\nPROF.OAK's PC.": "Verbindung zu\nPROF. EICHs PC\ngetrennt.",
    "Want to get your\nPOKéDEX rated?": "Soll dein POKéDEX\nbewertet werden?",
    "BILL's favorite\nPOKéMON list!": "BILLs Liste der\nLieblings-POKéMON!",
    "Bring out which\nPOKéMON?": "Welches POKéMON\nsoll heraus?",
    "Choose a POKéMON.": "Wähle ein POKéMON.",
    "No POKéMON!": "Keine POKéMON!",
    "You need at least\none POKéMON!": "Du brauchst\nmindestens ein\nPOKéMON!",
    "Do you want to\ngive a nickname\nto %s?": "Möchtest du %s\neinen Spitznamen\ngeben?",
}


def main():
    mod = Path(sys.argv[1] if len(sys.argv) > 1 else "mods/deutsch")
    path = mod / "lang" / "strings.lua"
    text = path.read_text()
    filled = [0]

    def quote(s):
        return '"%s"' % (s.replace("\\", "\\\\").replace('"', '\\"')
                          .replace("\n", "\\n"))

    def swap(m):
        key = m.group(1).encode().decode("unicode_escape")
        value = T.get(key)
        if not value:
            return m.group(0)
        filled[0] += 1
        return '[%s] = %s,' % (m.group(0).split("] =")[0][1:], quote(value))

    out = re.sub(r'\["((?:[^"\\]|\\.)*)"\]\s*=\s*"(?:[^"\\]|\\.)*",', swap, text)
    path.write_text(out)
    total = out.count('["')
    print("engine strings: %d / %d translated" % (filled[0], total))
    missing = total - filled[0]
    if missing:
        print("  %d still English (they fall back, which is the point)" % missing)


if __name__ == "__main__":
    main()
