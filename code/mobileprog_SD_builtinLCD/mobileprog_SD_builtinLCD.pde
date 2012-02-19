/*
 Firmware for MobileProg SD
 Mobile Arduino(TM) Programmer
 Harry Johnson, 11/24/10
 
 Thanks to Sparkfun Electronics for their amazing EAGLE libraries and tutorials on using the SD card. Some aspects of the SD file system code may resemble their example code.
 Thanks to Adafruit for getting me started in electronics with their easy to use kits.
 Also, thanks to the Arduino team for their LiquidCrystal library, for publishing their bootloader code, and for making it easy to access the HEX program files.
 
 Notes:
 1) Since I currently don't have any huge hex programs for the arduino mega, I don't yet know how they signify big numbers for the address (over 0xFFFF).
 As such, the program will not currently handle programs over 32K. Needs to be fixed.
 2) Designed for the Atmega328P on the device. However, by turning off either the on-the-go verify (recommended off anyway) or the progress bar, it can be squeezed (barely) onto an atmega168.
 3) Doesn't store what was in the target chip before attempting download, so if something goes wrong whatever is on the target before may be lost.
 
 TO USE:
 1)  Assemble board, using provided directions. (soon I shall have a website, and its link shall go here!)
 2)  Program MobileProg Chip using ISP programmer (if not already done)
 3)  Format SD card to FAT16
 4)  Compile desired sketch for target with verbose option on (hold down shift and press the verify button)
 5)  Navigate to directory shown in terminal window, and copy the .hex file to the SD card, and rename it something short and easy to remember. Keep the .hex extension, though! 
 6)  Plug SD card into MobileProg
 7)  Connect MobileProg to target board TX to RX, RX to TX, and 
 8)  Navigate to desired program using the "next" button.
 9)  Select desired program using the "select" button. 
 10) Enjoy!
 */
#include <SdFat.h> //SD fat volume library
#include <SdFatUtil.h> //basic SD access
#include <LiquidCrystal.h> //for the LCD display

// Utilities:
#define NIB2BYTE(h, l) ((h<<4) | l) // 2 nibbles to a byte. 
#define TWOSCOMP(x) (((x ^ 0xFF)+1) & 0xFF) //2's compliment of a byte.
#define HIBYTE(x) ((x>>8) & 0xFF) //high byte of a word
#define LOBYTE(x) (x & 0xFF) //low byte of a word


//pin numbers for software serial library
#define LCDRS 14
#define LCDE  15
#define LCDD4 16
#define LCDD5 17
#define LCDD6 18
#define LCDD7 19

//pin numbers for next, select, and target reset pins.
#define TARG_RESET 9
#define SELECT 2
#define NEXT 3

//STK constants
#define CRC_EOP             0x20
#define STK_OK              0x10
#define STK_INSYNC          0x14
#define STK_GET_SYNC        0x30
#define STK_LOAD_ADDRESS    0x55
#define STK_PROG_PAGE       0x64
#define STK_READ_PAGE       0x74
#define STK_READ_SIGN       0x75

//other constants
#define NUMLINEBYTES 16 //number of data bytes, maximum, per line of code. Probably best left at 16, unless something changes.
#define TIMEOUT 500 //.5 second comm timeout. can probably be brought down.
#define verify 0 // 0/1 for on-the-go verifying off/on
//file verify on: Low speed downloading, on the go error checking. This doesn't mean a ton since I don't store the original program for re-upload. Seems cool to have, though.
//file verify off: FAR Higher speed downloading, especially with big files. Recommended option. 
#define progressbar 1 // 0/1 for progress bar off/on. For large programs, the initial size calculation can take some time. Disable for even faster downloading. 

//data for current line of file.
word pageAddress; //word address
byte recordType; //EOF = 1
byte numPageBytes; //number of bytes so far on this page.
long int numTotalBytes = 0;
byte data[256]; //256 bytes, 128 words. maximum size, used for megas!
int pagesize = 0;

#if verify==1
byte tmp[256]; //save yourself some more ram by disabling verify.
#endif

//SD card variables
Sd2Card card;
SdVolume volume;
SdFile root;
SdFile file;

LiquidCrystal lcd(14, 15, 16, 17, 18, 19); //set up the LCD object.

void setup() {
  int errorcode = 0;
  pinMode(NEXT, INPUT); //select, next pins to input, enable internal pullup resistors.
  digitalWrite(NEXT, HIGH); 
  pinMode(SELECT, INPUT);
  digitalWrite(SELECT, HIGH);

  digitalWrite(TARG_RESET, HIGH); //defaults to not resetting the target.
  pinMode(TARG_RESET, OUTPUT);

  lcd.begin(16,2);  //connect to the LCD, 16x2
  lcd.cursor(); //turn off the cursor on the screen.
  
  if (!card.init(SPI_HALF_SPEED)) {
    lcd.println("Card init fail!"); //init card.
    while(1);
  }
  
  if (!volume.init(&card)) {
    lcd.println("Volume init fail!");      //init FAT volume
    while(1);
  }
  
  if (!root.openRoot(&volume)) {
    lcd.println("Root init fail!");    //open the root directory of the volume.
    while(1);  
  }
  
  if(selectPinFile() != 0) { //have the user select a file, and initialize it. 
    lcd.print("File init fail!");
    while(1);
  }

  if(initTarget() != 0) {
    lcd.print("device init fail!");  //initialize the target device.
    while(1); 
  }


  if(checkSig() != 0) {
    lcd.print("Signature mismatch!");  //connected, but not any of the right chips.
  }

#if progressbar == 1 //finding the total number of program bytes in the file. Can be disabled to save space.
  while(parsePage() != 1);
  long int fileSize = numTotalBytes;  
  file.rewind(); 
  numTotalBytes = 0;

  if(initTarget() != 0) { //initialize the target device again, since the counting may have taken so long the bootloader kicked us out.
    lcd.print("device init fail!");  
    while(1); 
  }
#endif

  lcd.clear(); //clear screen
  lcd.print("Programming");

  while(1) {
    if((errorcode = parsePage()) <0) { //parse a data page (not a page as in page 1, page 2.)
      lcd.print("error parsing");
      lcd.print(pageAddress);
      lcd.print(numPageBytes);
      lcd.print(errorcode);
      while(1);  
    }
    delay(10);

    if(programPage()<0) { //program the page we just parsed.
      lcd.print("error programming!"); 
      while(1);
    }

#if verify == 1 //checks the page we just uploaded. This takes forever!
    readPage(pageAddress, numPageBytes, (char *)tmp);
    for(int ii = 0; ii<pagesize; ii++) {
      if(data[ii] != tmp[ii]) {
        lcd.print("Verify Error."); 
        lcd.print(ii);
        while(1);
      }
    }
#endif

#if progressbar == 1 //printing out a progress bar, assumes 16x2 LCD. 
    lcd.setCursor(0,1);
    for(int ii = 0; ii<map(numTotalBytes, 0, fileSize, 0, 16); ii++) {
      lcd.print("*");
      delay(1);
    }
#endif

    if(errorcode ==1) { //errorcode = 1 then recordtype = 1, EOF.
      lcd.clear(); //clear the screen
      lcd.print("done!"); //tell the user we're done.
      Serial.write('Q');  //takes advantage of no-wait mod to autostart the program.
      while(1); 
    }
  } 
}

void loop() {
  //Move along, nothing to see here. Everything is handled in setup().
}

//STK500 PROTOCOL FUNCTIONS
void resetTarget() {
  digitalWrite(TARG_RESET, LOW); //pull the reset pin low.
  delay(100);
  digitalWrite(TARG_RESET, HIGH); //pull it back high.
  delay(10);
}

int initTarget () {
  lcd.clear();
  lcd.print("Testing optiboot");
  Serial.begin(115200); //optiboot
  Serial.flush();
  resetTarget();
  for(int ii = 0; ii<5; ii++) { //try to establish contact.
    Serial.flush();
    Serial.write(STK_GET_SYNC);
    Serial.write(CRC_EOP);
    if(checkResponse() ==0) { //the device responded properly.
      lcd.clear();
      delay(5);
      lcd.print("Optiboot"); //let the user know we have an optiboot device.
      delay(10);
      return 0;
    }
  } 
lcd.clear();
  lcd.print("Testing non-optiboot");
  Serial.begin(57600); //non-optiboot
  Serial.flush();
  resetTarget();
  for(int ii = 0; ii<5; ii++) { //establish contact.
    Serial.flush();
    Serial.write(STK_GET_SYNC);
    Serial.write(CRC_EOP);
    if(checkResponse() ==0) {
      lcd.clear(); //contact established
      lcd.print("57600");
      delay(500);
      return 0;
    }
  } 
  lcd.clear();
  lcd.print("Testing golden oldies");
  Serial.begin(12900); //very old bootloader. I probably shouldn't even support this. 
  Serial.flush();
  resetTarget();
  for(int ii = 0; ii<5; ii++) { //establishing contact...
    Serial.flush();
    Serial.write(STK_GET_SYNC);
    Serial.write(CRC_EOP);
    if(checkResponse() ==0) { //contact established.
      lcd.clear();
      lcd.print("12900");
      delay(100);
      return 0;
    }
  } 
  return -1; //nothing worked! umm.... maybe you didn't plug in the board? or plugged in wrong?

}

int checkResponse() { //checks that the bootloader returns STK_INSYNC and STK_OK
  int resp1, resp2;
  unsigned long curtime = millis();
  while(!Serial.available()) {
    if(millis()-curtime>TIMEOUT) return -1;
  }
  resp1=Serial.read();
  while(!Serial.available());
  resp2=Serial.read();
  if((resp1 != STK_INSYNC) && (resp2 != STK_OK))  return -1;
  return 0;
}

int loadAddress(word address) { 
  Serial.write(STK_LOAD_ADDRESS); //load page address into memory. This is the WORD address, which is byte address/2.
  Serial.write((byte)LOBYTE(pageAddress)); //low byte address
  Serial.write((byte)(HIBYTE(pageAddress))); //high byte address
  Serial.write(CRC_EOP); //next!
  if(checkResponse()<0) {
    lcd.print("Address fail.");
    return -1;
  } 
  return 0;
}

int programPage() { //STK500 program page.
  if(numPageBytes>0) {
    loadAddress(pageAddress);

    Serial.write(STK_PROG_PAGE); //let the bootloader know that data is coming.
    Serial.write((byte)0); //high byte of # ofbytes, always zero. amount of data <256 bytes.
    Serial.write((byte)numPageBytes); //low byte of# of bytes. 
    Serial.write("F"); //we are programming flash.
    Serial.write(data, numPageBytes); //write out all the bytes.

    Serial.write(CRC_EOP); // and we're done
    return checkResponse();
  }
}

int readPage(byte size, char *buffer) { //reads a page through STK500 protocol, given size and buffer.
  int tmp; //to store each incoming byte

  Serial.write(STK_READ_PAGE);
  Serial.write((byte)0); //high byte data size
  Serial.write((byte)size); //low byte data size.
  Serial.write("F");
  Serial.write(CRC_EOP);

  while(!Serial.available());
  if(Serial.read() != STK_INSYNC) return -1; 
  int ii = 0;
  while(ii<size) {
    if(Serial.available()>0) { //if something is there to read.
      tmp = Serial.read(); //read it
      buffer[ii] = (byte)(tmp); //store it
      ii++; //and record that we stored it.
    }  
    delay(1); //to prevent lockup.
  }
  if(Serial.read()!= STK_OK) return -1; 
  return 0;
}

int readPage(word address, byte size, char *buffer) { //reads page from a given WORD address, given the address, size, and buffer.
  loadAddress(address); //tell the target what memory to access
  return readPage(size, buffer); //and then pass off responsibility.
}

int checkSig() { //check the device signature and sets the page size (in bytes);
  Serial.flush();
  byte sig[3] = {0}; //to store the signature when it gets sent.
  Serial.write(STK_READ_SIGN); //STK command, read signature
  Serial.write(CRC_EOP);
  while(!Serial.available());
  if(Serial.read() != STK_INSYNC) return -1;
lcd.clear();
lcd.print("reading sig");
  for(int ii = 0; ii<3;ii++) {  //read the 3 signature bytes
    while(!Serial.available());
    sig[ii]=Serial.read(); 
  }

  if(Serial.read() != STK_OK) { lcd.clear(); lcd.print(" not OK"); return -1; }

  if((sig[0]==0x1E) && (sig[1]==0x94) && (sig[2]==0x0B)) {  
    pagesize = 64*2;  //atmega168P  pagesize 64 words * (2 bytes/word)
    lcd.clear(); 
    lcd.print("atmega168");
    return 0; 
  }
  if((sig[0]==0x1E) && (sig[1]==0x95) && (sig[2]==0x0F)) {
    pagesize = 64*2;  //atmega328P pagesize 64 words * (2 bytes/word)
    lcd.clear(); 
    lcd.print("atmega328p");
    return 0;
  } 
  if((sig[0]==0x1E) && (sig[1]==0x97) && (sig[2]==0x03)) {
    pagesize = 128*2; //atmega1280 pagesize 128 words * (2 bytes/word)
    return 0;
  } 
  if((sig[0]==0x1E) && (sig[1]==0x98) && (sig[2]==0x01)) {
    pagesize = 128*2; //atmega2560 pagesize 128 words * (2 bytes/word)
    return 0;
  } 
}

//END STK-500 PROTOCOL FUNCTIONS. 


// SD CARD READ, UI FUNCTIONS
char char2Hex(char c) { //convert char to hex number, aka 'A' to 0xA
  if (c>='0' && c<='9') return c-'0';
  if (c>='A' && c<='F') return c-'A'+10;
  if (c>='a' && c<='f') return c-'a'+10;
  return c=0;        // not Hex digit
}

int parsePage() { //parse a page from the HEX file, and store the data in memory.
  unsigned int checksum = 0; //for checksum summing.
  pageAddress = 0; //reset page address.
  byte numLineBytes = 0; //beauty of this is that we don't have to clear the data block every time.
  byte offset = 0; //to keep track of where we are in the buffer.
  word tmpAddress = 0; //to hold the byte address while we are going through. (for checksum summing.)
  recordType = 0; //normal 0, EOF 1.

  for(int ii = 0; ii<(pagesize/NUMLINEBYTES); ii++) { //need to read x number of lines. generally 8 lines*16 bytes/line =128bytes.
    checksum = 0; //reset checksum calculator.
    if(file.read()!=':') { //each line should begin with :
      Serial.print("File begin error"); 
      return -1;
    }
    numLineBytes =NIB2BYTE(char2Hex((char)file.read()),char2Hex((char)file.read())); //read the byte that tells us the num of bytes
    tmpAddress = word(NIB2BYTE(char2Hex((char)file.read()),char2Hex((char)file.read())), NIB2BYTE(char2Hex((char)file.read()),char2Hex((char)file.read()))); 
    if(ii==0) pageAddress = tmpAddress; //for the first line read, its address is the byte address.
    recordType=NIB2BYTE(char2Hex((char)file.read()), char2Hex((char)file.read())); //read the record type byte.  
    if(recordType==1) goto EOFJMP; //EOF
    if((numLineBytes>0) && (((recordType)==0) || (recordType ==3))) { //there is actually data there

      for(int jj = offset; jj<(offset+numLineBytes); jj++) { 
        data[jj]=NIB2BYTE(char2Hex((char)file.read()), char2Hex((char)file.read())); //read all of the data bytes. absurd array location math needed to make some arbitrary point in string the "zeroth" data item.
        checksum += data[jj];//running checksum total.
      }
      offset=offset+numLineBytes; //where to start in the buffer next time?
    }
    checksum += numLineBytes+((tmpAddress & 255) +((tmpAddress>>8)& 255)) + recordType; //sum of data size byte, address bytes, record type, and all data bytes.
    checksum = TWOSCOMP(checksum); //generate the two's compliment (official checksum)
    if(checksum!=NIB2BYTE(char2Hex((char)file.read()), char2Hex((char)file.read()))) return -2; //if checksum doesn't check out, RUN!
    file.read(); //seems to be necessary. Probably LF/CR
    file.read();
  }
EOFJMP: //end of file
  numPageBytes = offset; //been summing the whole time.
  numTotalBytes += (numPageBytes); //for progress bar.
  pageAddress=pageAddress/2; //byte address to word address.
  if(recordType==1) return 1; //EOF
  return 0;
}

int selectPinFile() { //select a file, using the button UI
  char filename[13]; //storing filename.
  dir_t dir; //directory
  int stateSelect = HIGH; //state of the "select" pin. Low = pressed
  int stateNext = HIGH; //state of the "next" pin. Low = pressed
  int fileUpdated = 1; //Has the filename been updated? (To keep it from printing to the LCD forever.)
  goto nextFile; //get the first file, regardless of input.

  while(1) {

    if((digitalRead(NEXT)==LOW) && (stateNext==HIGH)) { //if the button is pressed and it wasn't before.
nextFile:
      if (root.readDir(dir) != sizeof(dir)) { //if we reach the end of the directory, go back and start again.
        root.rewind();
        root.readDir(dir);
      }
      fileUpdated = 1; //we have a new file!
    }
    if(fileUpdated>0) { //if there is a new file.
      SdFile::dirName(dir, filename);
      for(int ii = 0; ii<13; ii++) {
        if((filename[ii] == '.') && (filename[ii+1] == 'H') && (filename[ii+2] == 'E') && (filename[ii+3] == 'X')) { //if the file extension is ".hex"
          goto HexFile; //the file is hex.
        }
      }
      goto nextFile; //if the file isn't a hex file, get the next one. 
HexFile: 
      lcd.clear();
      lcd.print("File: ");
      lcd.println(filename); //print the filename.
      fileUpdated=0;
    }
    if((digitalRead(SELECT)==LOW) && (stateSelect==HIGH)) { //if the user hit the "select" button.
      if(!(file.open(root, filename, O_READ))) return -1; //the file didn't open. Oh no. 
      lcd.clear();
      lcd.print("file chosen!");
      goto fileselected; //the file did open. let's get out of here!
    }
    stateNext = digitalRead(NEXT); //if the end hasn't been reached, store the value of the pins, then go back up to the top.
    stateSelect = digitalRead(SELECT);
    delay(10);
  }
fileselected:
  file.rewind(); //go to the beginning of the file, just in case.
  return 0; 
}

//END OF SD READ/UI FUNCTIONS











