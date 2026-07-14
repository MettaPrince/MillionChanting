const express = require('express');
const http = require('http');
const { Server } = require('socket.io');
const speech = require('@google-cloud/speech');
const path = require('path');

const app = express();
const server = http.createServer(app);
const io = new Server(server);

// ให้ Express เสิร์ฟไฟล์หน้าเว็บจากโฟลเดอร์ public
app.use(express.static(path.join(__dirname, 'public')));

// โหลดกุญแจ Google Cloud จากไฟล์ key.json ที่เราเพิ่งเปลี่ยนชื่อ
let speechClient;
try {
    speechClient = new speech.SpeechClient({
        keyFilename: path.join(__dirname, 'key.json')
    });
} catch (err) {
    console.error('ไม่พบไฟล์ key.json กรุณาตรวจสอบชื่อไฟล์', err);
}

io.on('connection', (socket) => {
    console.log('มีผู้ใช้งานเชื่อมต่อเข้ามา:', socket.id);
    let recognizeStream = null;

    socket.on('start-recognition', () => {
        console.log('เริ่มส่งเสียงไปที่ Google Cloud...');

        // 🟢 เพิ่มบล็อกนี้: เตะตัดสายสตรีมเก่าทิ้งทันที หากมีการกดเริ่มใหม่ซ้อนเข้ามา
        if (recognizeStream) {
            recognizeStream.end();
            recognizeStream = null;
        }

        const request = {
            config: {
                encoding: 'WEBM_OPUS',
                sampleRateHertz: 48000,
                languageCode: 'th-TH',
                model: 'latest_long',
                speechContexts: [{
                    // หั่นคำให้สั้นลง และใส่คำอ่านที่เสียงคล้ายกันลงไปดัก
                    phrases: [
                        // 🟢 1. ดักรอยต่อระหว่างจบ (ทำให้ AI รู้ว่าถ้าจบ ฤๅ แล้ว ต่อไปคือ สัมปะ แน่นอน)
                        "ฤๅ สัมปะจิตฉามิ", "ลือ สัมปะจิตฉามิ", "รือ สัมปะจิตฉามิ",
                        // 🟢 2. ดักประโยคยาว (ทำให้ AI ไม่ต้องรอเดาบริบท มันจะเดามาให้ทั้งก้อนเลย)
                        // "สัมปะจิตฉามิ นาสังสิโม",

                        "สัมปะจิตฉามิ",
                        "นาสังสิโม", "นาสัง", "สังสิโม", "สิโม",
                        "พรัหมา", "พรมมา", "พรัมมา", "จะ", "มหาเทวา", "สัพเพ", "ยักขา", "ปะรายันติ",
                        "พรัหมา", "พรมมา", "พรัมมา", "จะ", "มหาเทวา", "อภิลาภา", "ภะวันตุเม", "ภะวันตุ", "เม",
                        "มหาปุญโญ", "ปุญโญ", "มหาลาโภ", "ลาโภ", "ภะวันตุเม", "ภะวันตุ", "เม", "มิเต", "มีเต", "ภาหุ", "มิเตภาหุหะติ", "หุหะติ", "หะติ",
                        "พุทธะมะอะอุ", "มะอะอุ", "นะโมพุทธายะ", "นะโม", "พุทธายะ",
                        "วิระทะโย", "ทะโย", "วิระโคนายัง", "โคนา", "วิระหิงสา", "หิงสา",
                        "วิระทาสี", "ทาสี", "วิระทาสา", "ทาสา", "วิระอิตถิโย", "อิตถิโย", "อิตถิ", "ถิโย",
                        "พุทธัสสะ", "มานี", "มานีมามะ", "มามะ", "สวา", "สะหวา", "สวาโหม", "วาโหม", "โหม",
                        "สัมปะติจฉามิ", "เพ็งเพ็ง", "พาพา", "หาหา", "ฤๅฤๅ", "ลือลือ", "รือรือ", "พา", "หา", "ฤๅ", "ลือ", "รือ"
                    ],
                    // ปกติ Google แนะนำที่ 10-20 แต่เราจะอัดไปที่ 100 เพื่อบังคับให้มันเลือกคำพวกนี้ก่อน
                    boost: 100.0
                }]
            },
            interimResults: true
        };

        try {
            recognizeStream = speechClient
                .streamingRecognize(request)
                .on('error', console.error)
                .on('data', (data) => {
                    if (data.results[0] && data.results[0].alternatives[0]) {
                        const transcript = data.results[0].alternatives[0].transcript;
                        socket.emit('speech-data', { transcript });
                    }
                });
        } catch (err) {
            console.error('เกิดข้อผิดพลาด:', err);
        }
    });

    // รับไฟล์เสียงจากหน้าเว็บส่งต่อให้ Google
    socket.on('audio-chunk', (chunk) => {
        if (recognizeStream) recognizeStream.write(chunk);
    });

    socket.on('stop-recognition', () => {
        if (recognizeStream) {
            recognizeStream.end();
            recognizeStream = null;
        }
    });

    socket.on('disconnect', () => {
        if (recognizeStream) {
            recognizeStream.end();
            recognizeStream = null;
        }
    });
});

// เปลี่ยนจาก const PORT = 3000; เป็นการเช็ค Port ของ Cloud ก่อน
const PORT = process.env.PORT || 3000;

server.listen(PORT, () => {
    console.log(`เซิร์ฟเวอร์ทำงานแล้วที่ Port: ${PORT}`);
    console.log(`หากรันบนเครื่องตัวเองให้เข้า: http://localhost:${PORT}`);
});