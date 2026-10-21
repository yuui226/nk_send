package com.ztransfer.grain;

import java.awt.Color;
import java.awt.Font;
import java.awt.Graphics2D;
import java.awt.image.BufferedImage;
import java.io.File;
import java.util.Arrays;
import javax.imageio.ImageIO;

// Matches the production JNI descriptor without requiring Android on the host.
class NativePhotoGrain {
    static native void applyBatch(int[] pixels, int start, int count, int tileWidth, int pixelOffset,
        int fullWidth, int fullHeight, int originX, int originY, int orientation, int intensity, int seed, int style);
}

public class PhotoGrainJniTest {
    private static final int SEED = 0x5a544752;

    private static void expectInvalid(Runnable action) {
        try { action.run(); throw new AssertionError("Expected invalid batch"); }
        catch (IllegalArgumentException expected) { }
    }

    private static int[] render(int[] original, int width, int height, int strength, int batchSize, int style) {
        int[] output = original.clone();
        for (int offset = 0; offset < output.length; offset += batchSize) {
            int count = Math.min(batchSize, output.length - offset);
            NativePhotoGrain.applyBatch(output, offset, count, width, offset,
                width, height, 0, 0, 1, strength, SEED, style);
        }
        return output;
    }

    public static void main(String[] args) throws Exception {
        System.load(args[0]);
        int[] pixels = new int[20000];
        Arrays.fill(pixels, 0x7f808080);
        expectInvalid(() -> NativePhotoGrain.applyBatch(null,0,1,100,0,100,200,0,0,1,50,SEED,0));
        expectInvalid(() -> NativePhotoGrain.applyBatch(pixels,-1,1,100,0,100,200,0,0,1,50,SEED,0));
        expectInvalid(() -> NativePhotoGrain.applyBatch(pixels,0,16385,100,0,100,200,0,0,1,50,SEED,0));
        expectInvalid(() -> NativePhotoGrain.applyBatch(pixels,19999,2,100,0,100,200,0,0,1,50,SEED,0));
        expectInvalid(() -> NativePhotoGrain.applyBatch(pixels,0,1,0,0,100,200,0,0,1,50,SEED,0));
        expectInvalid(() -> NativePhotoGrain.applyBatch(pixels,0,1,100,-1,100,200,0,0,1,50,SEED,0));
        expectInvalid(() -> NativePhotoGrain.applyBatch(pixels,0,1,100,20000,100,200,0,0,1,50,SEED,0));
        expectInvalid(() -> NativePhotoGrain.applyBatch(pixels,0,1,100,Integer.MAX_VALUE,100,200,0,0,1,50,SEED,0));
        expectInvalid(() -> NativePhotoGrain.applyBatch(pixels,0,1,100,0,100,200,1,0,1,50,SEED,0));
        expectInvalid(() -> NativePhotoGrain.applyBatch(pixels,0,1,100,0,100,200,0,-1,1,50,SEED,0));
        expectInvalid(() -> NativePhotoGrain.applyBatch(pixels,0,1,100,0,100,200,0,200,1,50,SEED,0));
        expectInvalid(() -> NativePhotoGrain.applyBatch(pixels,0,1,100,0,100,200,0,0,9,50,SEED,0));
        expectInvalid(() -> NativePhotoGrain.applyBatch(pixels,0,1,100,0,100,200,0,0,1,101,SEED,0));
        int[][] styles = new int[3][];
        for (int style = 0; style < 3; style++) {
            int[] whole = render(pixels, 100, 200, 100, 16384, style);
            int[] pieces = render(pixels, 100, 200, 100, 397, style);
            if (!Arrays.equals(whole, pieces)) throw new AssertionError("JNI batch split mismatch");
            if (!Arrays.equals(pixels, render(pixels,100,200,0,16384,style))) throw new AssertionError("OFF changed pixels");
            styles[style] = whole;
        }
        if (Arrays.equals(styles[0], styles[1]) || Arrays.equals(styles[1], styles[2]))
            throw new AssertionError("JNI style selection did not alter the texture");
        expectInvalid(() -> NativePhotoGrain.applyBatch(pixels,0,1,100,0,100,200,0,0,1,50,SEED,-1));
        expectInvalid(() -> NativePhotoGrain.applyBatch(pixels,0,1,100,0,100,200,0,0,1,50,SEED,3));
        NativePhotoGrain.applyBatch(pixels, pixels.length, 0, 100, 0, 100, 200, 0, 0, 1, 50, SEED, 0);
        System.out.println("JNI invalid bounds/overflow/null/OFF/empty/arbitrary batch splits passed");

        if (args.length < 2) return;
        File directory = new File(args[1]);
        if (!directory.isDirectory() && !directory.mkdirs()) throw new IllegalStateException("Cannot create output");
        // A smooth source deliberately exposes grain/aliasing that JPEG texture could hide.
        int width = 1920, height = 1280;
        int[] source = new int[width * height];
        for (int y = 0; y < height; y++) for (int x = 0; x < width; x++) {
            double u = x / (double)(width - 1);
            int r, g, b;
            if (y < height / 2) {
                double value = .12 + .76 * u;
                r = (int)(255 * value); g = r; b = r;
            } else {
                r = (int)(70 + 140 * u); g = (int)(60 + 130 * (1 - u));
                b = (int)(110 + 80 * Math.sin(u * Math.PI));
            }
            source[y * width + x] = 0xff000000 | r << 16 | g << 8 | b;
        }
        BufferedImage contact = new BufferedImage(1280, 848, BufferedImage.TYPE_INT_RGB);
        Graphics2D canvas = contact.createGraphics();
        canvas.setFont(new Font("SansSerif", Font.PLAIN, 20));
        int panel = 0;
        for (int strength : new int[] {0, 25, 50, 100}) {
            long start = System.nanoTime();
            int[] output = render(source,width,height,strength,16384,0);
            double renderSeconds = (System.nanoTime()-start)/1e9;
            BufferedImage image = new BufferedImage(width,height,BufferedImage.TYPE_INT_RGB);
            image.setRGB(0,0,width,height,output,0,width);
            ImageIO.write(image,"png",new File(directory,"grain-"+strength+".png"));
            // 1:1 crop, not a resized screenshot of the noise.
            BufferedImage crop = image.getSubimage(600,450,640,400);
            int left = panel % 2 * 640, top = panel / 2 * 424;
            canvas.drawImage(crop,left,top+24,null);
            canvas.setColor(Color.BLACK); canvas.fillRect(left,top,640,24);
            canvas.setColor(Color.WHITE); canvas.drawString(strength+"% — 1:1 pixels",left+12,top+20);
            panel++;
            System.out.printf("1920 preview %d%% (excluding PNG I/O): %.3fs\n",strength,renderSeconds);
        }
        canvas.dispose();
        ImageIO.write(contact,"png",new File(directory,"grain-comparison-1x.png"));

        BufferedImage styleContact = new BufferedImage(1920, 848, BufferedImage.TYPE_INT_RGB);
        Graphics2D styleCanvas = styleContact.createGraphics();
        styleCanvas.setFont(new Font("SansSerif", Font.PLAIN, 20));
        String[] names = {"Fine", "Medium", "Coarse"};
        for (int style = 0; style < 3; style++) {
            int row = 0;
            for (int strength : new int[] {50, 100}) {
                long start = System.nanoTime();
                int[] output = render(source,width,height,strength,16384,style);
                double seconds = (System.nanoTime()-start)/1e9;
                BufferedImage image = new BufferedImage(width,height,BufferedImage.TYPE_INT_RGB);
                image.setRGB(0,0,width,height,output,0,width);
                ImageIO.write(image,"png",new File(directory,"grain-"+names[style]+"-"+strength+".png"));
                int left = style * 640, top = row * 424;
                styleCanvas.drawImage(image.getSubimage(600,450,640,400),left,top+24,null);
                styleCanvas.setColor(Color.BLACK); styleCanvas.fillRect(left,top,640,24);
                styleCanvas.setColor(Color.WHITE);
                styleCanvas.drawString(names[style]+" "+strength+"% — 1:1 pixels",left+12,top+20);
                System.out.printf("1920 style=%s strength=%d%% (excluding PNG I/O): %.3fs\n",names[style],strength,seconds);
                row++;
            }
        }
        styleCanvas.dispose();
        ImageIO.write(styleContact,"png",new File(directory,"grain-styles-1x.png"));
        System.out.println("Visual fixtures: " + directory.getAbsolutePath());
    }
}
